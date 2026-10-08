# Admission pacing uses the verified cycle's first outgoing transfer phase.
# It is separate from transfer ranks, and never changes a started operation.
release_enabled(app)=!app.replay_mode && app.config["optimizer"]["delay_job_release"] &&
    app.config["control"]["mode"] in ("optimized_priority","fixed_priority")

function install_release_pattern!(app,solution,req;preserve_anchor=false)
    release_enabled(app) || return
    timing_enabled(app) && return install_timing_pattern!(app,solution,req)
    phases=Dict{Int,Float64}();fallback_jobs=nothing
    for (a,event) in enumerate(solution["events"])
        r,i=Int.(event);i==1 || continue
        # For the selected L/U/midpoint processing duration, finish the first
        # operation at its cyclic pickup phase. No in-flight state is retimed.
        m=findfirst(m->m["route_id"]==r,req["mapping"])
        id=m===nothing ? nothing : req["mapping"][m]["job_id"]
        job=id===nothing ? nothing : get(app.sim.jobs,id,nothing)
        if job===nothing
            if fallback_jobs===nothing
                raw=deepcopy(app.problem)
                raw["import_options"]=merge(get(app.config,"import_options",Dict()),Dict("copies_per_route"=>1))
                fallback_jobs=JS.normalize_config(raw)["jobs"]
            end
            duration=fallback_jobs[r]["operations"][1]["duration"]
        else
            duration=job.operations[1].duration
        end
        phases[r]=mod(Float64(solution["starts"][a])-duration,Float64(solution["T"]))
    end
    previous=app.release_pattern
    anchor=preserve_anchor && previous!==nothing ? previous["anchor"] : app.sim.time
    app.release_pattern=Dict("period"=>Float64(solution["T"]),"phases"=>phases,
        "anchor"=>anchor,"request_id"=>req["request_id"])
    if previous!==nothing
        advance_waiting_releases!(app,req)
    end
    for m in sort(collect(values(app.mapping));by=m->(m["route_id"],m["instance_index"]))
        plan_job_release!(app,m["job_id"])
    end
end

# Only advance jobs which have never entered a machine. Actual admissions and
# all in-flight work stay fixed; no published reservation moves later.
function advance_waiting_releases!(app,req)
    pattern=app.release_pattern;T=pattern["period"];now=app.sim.time
    pending=Dict{Int,Vector{String}}();last_admitted=Dict{Int,Float64}()
    for (id,plan) in app.release_plans
        route=plan["route_id"];route===nothing && continue
        if plan["actual_at"]!==nothing
            last_admitted[route]=max(get(last_admitted,route,-Inf),Float64(plan["actual_at"]))
        elseif haskey(app.sim.jobs,id) && app.sim.jobs[id].status=="waiting_release"
            push!(get!(pending,route,String[]),id)
        end
    end
    changed=Dict{String,Float64}();max_advance=0.0
    for (route,ids) in pending
        haskey(pattern["phases"],route) || continue
        sort!(ids;by=id->(app.release_plans[id]["planned_at"],get(app.mapping[id],"instance_index",0),id))
        base=pattern["anchor"]+pattern["phases"][route]
        earliest=max(now,get(last_admitted,route,-Inf)+T)
        for id in ids
            plan=app.release_plans[id];old=Float64(plan["planned_at"])
            floor=max(earliest,Float64(plan["requested_at"]))
            slot=base+max(0,ceil(Int,(floor-base-1e-8)/T))*T
            at=min(old,max(now,slot))
            if at<old-1e-8
                get!(plan,"initial_planned_at",old)
                plan["previous_planned_at"]=old;plan["rescheduled_at"]=now
                plan["planned_at"]=at;plan["request_id"]=req["request_id"]
                changed[id]=at
                max_advance=max(max_advance,old-at)
            end
            earliest=at+T
        end
    end
    if !isempty(changed)
        app.sim.events=[e.kind=="release_job" && haskey(changed,e.payload) ?
            JS.InputEvent(changed[e.payload],e.sequence,e.kind,e.payload,e.source) : e for e in app.sim.events]
        sort!(app.sim.events;by=e->(e.at,e.sequence))
        JS.record!(app.sim,"job_release_rescheduled";jobs_count=length(changed),period=T,
            request_id=req["request_id"],next_release_at=minimum(values(changed)),max_advance_seconds=max_advance)
    end
    length(changed)
end

function defer_job_release!(app,id,at;request_id=nothing,sim=app.sim)
    job=get(sim.jobs,id,nothing)
    job===nothing && return
    job.index==1 && job.status=="queued" && job.processed==0 || return
    at>sim.time+1e-8 || return
    for machine in values(sim.machines);filter!(!=(id),machine.queue);end
    job.status="waiting_release"
    app.release_plans[id]=Dict("job_id"=>id,"route_id"=>get(get(app.mapping,id,Dict()),"route_id",nothing),
        "requested_at"=>job.entered,"planned_at"=>at,"actual_at"=>nothing,"request_id"=>request_id)
    JS.enqueue!(sim,"release_job",at,id,"optimizer")
    JS.record!(sim,"job_release_planned";job=id,requested_at=job.entered,planned_at=at,request_id)
end

function plan_job_release!(app,id)
    release_enabled(app) && app.release_pattern!==nothing || return
    timing_enabled(app) && return plan_timed_job!(app,id)
    haskey(app.release_plans,id) && return
    haskey(app.mapping,id) && haskey(app.sim.jobs,id) || return
    job=app.sim.jobs[id]
    job.index==1 && job.status=="queued" && job.processed==0 || return
    pattern=app.release_pattern;r=app.mapping[id]["route_id"]
    haskey(pattern["phases"],r) || return
    T=pattern["period"];base=pattern["anchor"]+pattern["phases"][r]
    at=base+max(0,ceil(Int,(app.sim.time-base-1e-8)/T))*T
    # One admission per route per cycle. Include jobs already admitted at a slot.
    occupied=[p["planned_at"] for p in values(app.release_plans) if p["route_id"]==r]
    while any(t->abs(t-at)<T-1e-8,occupied);at+=T;end
    if at<=app.sim.time+1e-8
        app.release_plans[id]=Dict("job_id"=>id,"route_id"=>r,"requested_at"=>job.entered,
            "planned_at"=>app.sim.time,"actual_at"=>app.sim.time,"request_id"=>pattern["request_id"])
    else
        defer_job_release!(app,id,at;request_id=pattern["request_id"])
    end
end

function clear_release_pattern!(app)
    clear_timing_pattern!(app)
    app.release_pattern=nothing
    # A mode/solver/count change must not leave jobs waiting for an obsolete cycle.
    for (id,plan) in app.release_plans
        get(plan,"actual_at",nothing)===nothing || continue
        plan["planned_at"]=app.sim.time
    end
    app.sim.events=[e.kind=="release_job" ? JS.InputEvent(app.sim.time,e.sequence,e.kind,e.payload,e.source) : e for e in app.sim.events]
    sort!(app.sim.events;by=e->(e.at,e.sequence))
    JS.advance!(app.sim,app.sim.time)
end
