# Strict appointments are simulation events, independent of wall-clock/UI ticks.
timing_enabled(app)=get(app.config["optimizer"],"transfer_execution","priority")=="cyclic_timing" &&
    app.config["control"]["mode"] in ("optimized_priority","fixed_priority")
timing_failed(app)=app.timing_pattern!==nothing && app.timing_pattern["error"]!==nothing
const TIMING_TOLERANCE=1e-7

function timing_templates(app,solution)
    p=SolverVerification.problem_from_dict(app.problem)
    templates=Dict{Int,Any}();previous=Dict{Int,Int}();lifts=zeros(Int,length(solution["events"]))
    for (a,event) in enumerate(solution["events"])
        r,i=Int.(event);b=get(previous,r,0)
        b!=0 && (lifts[a]=lifts[b]+Int(solution["k"][a])-1+Int(solution["y"][a][b]))
        row=get!(templates,r,Dict("times"=>Float64[],"durations"=>Float64[],"hoists"=>Any[],"travel_before"=>Float64[]))
        at=Float64(solution["starts"][a])+lifts[a]*Float64(solution["T"])
        dwell=b==0 ? Float64(app.problem["L"][1][r]) : at-last(row["times"])-p.duration[b]
        dwell>=-TIMING_TOLERANCE || throw(ArgumentError("周期パターンの工程時刻が逆転しています"))
        push!(row["times"],at);push!(row["durations"],max(0.0,dwell))
        push!(row["travel_before"],b==0 ? 0.0 : Float64(p.duration[b]))
        push!(row["hoists"],p.terminal[a] ? nothing : Int(solution["hoists"][a])+1)
        previous[r]=a
    end
    templates
end

function unstarted_timed_job(job)
    job.index==1 && job.processed==0 && job.status in ("queued","waiting_release")
end
function set_timed_durations!(job,durations;travel_before=nothing)
    for i in eachindex(job.operations)
        op=job.operations[i]
        travel=travel_before===nothing || i==1 ? op.travel_before : travel_before[i]===nothing ? nothing : Float64(travel_before[i])
        job.operations[i]=JS.Operation(op.machine,Float64(durations[i]),travel,op.travel_times,op.members)
    end
    job.remaining=job.operations[1].duration
end

function install_timing_pattern!(app,solution,req)
    timing_failed(app) && return # A violated appointment requires an explicit recovery/reset.
    templates=timing_templates(app,solution);T=Float64(solution["T"])
    signature=canonical(Dict("period"=>T,"templates"=>Dict(string(r)=>t for (r,t) in templates)))
    prior=app.timing_pattern
    if prior!==nothing && prior["signature"]==signature
        for id in app.sim.job_order;plan_timed_job!(app,id);end
        return
    end
    plans=Dict{String,Any}();drain_until=app.sim.time
    if prior!==nothing
        for (id,plan) in prior["jobs"]
            job=get(app.sim.jobs,id,nothing)
            job===nothing && continue
            if job.status!="completed" && !unstarted_timed_job(job)
                plans[id]=plan # Pin WIP to the verified pattern it started with.
                drain_until=max(drain_until,last(plan["times"]))
            end
        end
    end
    anchor=max(drain_until,app.sim.time+maximum(first(t["durations"])-first(t["times"]) for t in values(templates)))
    originals=prior===nothing ? Dict{String,Any}() : Dict(id=>p["original_durations"] for (id,p) in prior["jobs"])
    original_travel=prior===nothing ? Dict{String,Any}() : Dict(id=>p["original_travel_before"] for (id,p) in prior["jobs"] if haskey(p,"original_travel_before"))
    app.timing_pattern=Dict{String,Any}("period"=>T,"anchor"=>anchor,"templates"=>templates,"signature"=>signature,"original_durations"=>originals,"original_travel_before"=>original_travel,
        "request_id"=>req["request_id"],"jobs"=>plans,"next_slots"=>Dict{Int,Int}(),"error"=>nothing,
        "matched"=>prior===nothing ? 0 : prior["matched"],"max_error_seconds"=>prior===nothing ? 0.0 : prior["max_error_seconds"])
    app.release_pattern=Dict("period"=>T,"anchor"=>anchor,"phases"=>Dict(r=>first(t["times"])-first(t["durations"]) for (r,t) in templates),"request_id"=>req["request_id"])
    wip_count=length(plans)
    for id in app.sim.job_order
        job=app.sim.jobs[id]
        unstarted_timed_job(job) && pop!(app.release_plans,id,nothing)
    end
    for m in sort(collect(values(app.mapping));by=m->(m["route_id"],m["instance_index"]))
        plan_timed_job!(app,m["job_id"])
    end
    JS.record!(app.sim,"cyclic_timing_pattern_applied";request_id=req["request_id"],period=T,anchor,wip_jobs=wip_count)
end

function plan_timed_job!(app,id)
    state=app.timing_pattern;state===nothing && return
    haskey(state["jobs"],id) && return
    job=get(app.sim.jobs,id,nothing);job===nothing && return
    job.status=="completed" && return
    mapping=get(app.mapping,id,nothing)
    if mapping===nothing || !unstarted_timed_job(job)
        fail_timing!(app,app.sim,id,"原品種に対応しないJOB、または着手済みJOBのため周期時刻を割り当てられません")
        return
    end
    r=Int(mapping["route_id"]);template=state["templates"][r];T=state["period"]
    base=state["anchor"]+first(template["times"])-first(template["durations"])
    slot=max(get(state["next_slots"],r,0),max(0,ceil(Int,(app.sim.time-base-TIMING_TOLERANCE)/T)))
    state["next_slots"][r]=slot+1
    offset=state["anchor"]+slot*T;release_at=base+slot*T
    original=get!(state["original_durations"],id) do;[op.duration for op in job.operations];end
    original_travel=get!(state["original_travel_before"],id) do;[op.travel_before for op in job.operations];end
    plan=Dict{String,Any}("job_id"=>id,"route_id"=>r,"period"=>T,"times"=>template["times"].+offset,
        "hoists"=>template["hoists"],"durations"=>template["durations"],"original_durations"=>original,
        "travel_before"=>template["travel_before"],"original_travel_before"=>original_travel,
        "next_source"=>1,"release_at"=>release_at,"request_id"=>state["request_id"])
    state["jobs"][id]=plan;set_timed_durations!(job,plan["durations"];travel_before=plan["travel_before"])
    # Strict mode owns reservations; a new unstarted cycle may move them later.
    filter!(e->!(e.kind=="release_job"&&e.payload==id),app.sim.events)
    if release_at>app.sim.time+TIMING_TOLERANCE
        job.status="queued";defer_job_release!(app,id,release_at;request_id=state["request_id"])
    else
        job.status=="waiting_release" && JS.queue_job!(app.sim,job)
        app.release_plans[id]=Dict("job_id"=>id,"route_id"=>r,"requested_at"=>job.entered,
            "planned_at"=>app.sim.time,"actual_at"=>app.sim.time,"request_id"=>state["request_id"])
    end
    JS.record!(app.sim,"cyclic_job_planned";job=id,plan=deepcopy(plan))
end

function fail_timing!(app,sim,id,reason;planned_at=nothing)
    state=app.timing_pattern;state===nothing && return
    state["error"]!==nothing && return
    state["error"]=Dict("job_id"=>id,"reason"=>reason,"time"=>sim.time,"planned_at"=>planned_at)
    app.running=false
    JS.record!(sim,"cyclic_timing_missed";job=id,reason,planned_at)
end

function timing_target(sim,job)
    JS.available_group_machine(sim,job) # Include single machines, faults and reservations.
end

# The cyclic model excludes the zero-length initial loading stage from tank
# capacity (its event has no predecessor). It is an external loading point,
# even when the same station number also denotes occupied discharge slots.
function settle_timed_loading!(app,sim)
    timing_enabled(app) && !timing_failed(app) || return
    state=app.timing_pattern;state===nothing && return
    for id in sim.job_order
        job=sim.jobs[id]
        job.status=="queued" && job.index==1 && job.remaining==0 && length(job.operations)>1 || continue
        plan=get(state["jobs"],id,nothing);plan===nothing && continue
        abs(first(plan["times"])-sim.time)<=TIMING_TOLERANCE || continue
        origin=findfirst(m->!sim.machines[m].failed,job.operations[1].members)
        origin===nothing && continue
        machine=job.operations[1].members[origin]
        for m in values(sim.machines);filter!(!=(id),m.queue);end
        JS.record!(sim,"operation_started";job=id,machine,group=job.operations[1].machine,operation=1,external_loading=true)
        JS.record!(sim,"operation_completed";job=id,machine,operation=1,external_loading=true)
        job.index=2;job.remaining=job.operations[2].duration;job.assigned_machine=nothing
        JS.start_transfer!(sim,job,machine)
    end
end

# Reservations protect a future arrival, not the whole preceding travel time.
# A scheduled JOB can use an empty reserved machine only if it will leave by
# that arrival. Keep the original reservation and the in-flight JOB untouched.
function timing_machine_dispatch_allowed(app,sim,job,id)
    haskey(sim.machine_reservations,id) || return true
    timing_enabled(app) && !timing_failed(app) || return false
    state=app.timing_pattern;state===nothing && return false
    plan=get(state["jobs"],job.id,nothing);plan===nothing && return false
    incoming=get(sim.jobs,sim.machine_reservations[id],nothing)
    incoming!==nothing && incoming.status=="moving" && incoming.travel_until!==nothing || return false
    pickup=plan["times"][job.index]
    pickup>=sim.time-TIMING_TOLERANCE && max(pickup,sim.time+job.remaining)<=incoming.travel_until+TIMING_TOLERANCE
end
function check_timing_deadlines!(app,sim)
    timing_enabled(app) || return
    state=app.timing_pattern;state===nothing && return
    timing_failed(app) && return
    for (id,plan) in state["jobs"]
        j=get(sim.jobs,id,nothing);j===nothing && continue
        i=plan["next_source"];i>length(plan["times"]) && continue
        at=plan["times"][i];at>sim.time+TIMING_TOLERANCE && continue
        reason=if sim.time>at+TIMING_TOLERANCE
            "指定搬送時刻を超過しました"
        elseif i==length(plan["times"])
            j.status=="completed" ? nothing : "指定した終端時刻に処理が完了していません"
        elseif j.status!="waiting_transport" || j.index!=i+1
            "指定搬送時刻に工程の処理が完了していません"
        elseif sim.machines[j.travel_from].failed
            "搬送元の機械が故障しています"
        elseif timing_target(sim,j)===nothing
            "搬送先の機械が故障・占有・予約中です"
        elseif sim.transporters[plan["hoists"][i]].active!==nothing
            "パターンで指定した搬送機が使用中です"
        else
            nothing
        end
        reason===nothing || (fail_timing!(app,sim,id,reason;planned_at=at);return)
    end
end

function next_timing_boundary(app,sim)
    timing_enabled(app) || return nothing
    state=app.timing_pattern;state===nothing && return nothing
    timing_failed(app) && return sim.time
    at=Inf
    for (id,plan) in state["jobs"]
        haskey(sim.jobs,id) || continue
        i=plan["next_source"];i>length(plan["times"]) && continue
        when=plan["times"][i]
        when>sim.time+TIMING_TOLERANCE && (at=min(at,when))
    end
    isfinite(at) ? at : nothing
end

function timing_position(app,sim,index)
    state=app.timing_pattern
    (state===nothing || timing_failed(app)) && return nothing
    for (pos,id) in enumerate(sim.transfer_queue)
        plan=get(state["jobs"],id,nothing);plan===nothing && continue
        source=sim.jobs[id].index-1
        source==plan["next_source"] && plan["hoists"][source]==index || continue
        abs(plan["times"][source]-sim.time)<=TIMING_TOLERANCE || continue
        timing_target(sim,sim.jobs[id])===nothing && continue
        return pos
    end
    nothing
end

function observe_timing!(app,sim,e)
    timing_enabled(app) || return
    state=app.timing_pattern;state===nothing && return
    e["type"] in ("transfer_started","transfer_consumed","job_completed") || return
    id=e["job"];plan=get(state["jobs"],id,nothing);plan===nothing && return
    source=e["type"]=="job_completed" ? length(plan["times"]) : get(e,"source_operation",sim.jobs[id].index-1)
    difference=abs(sim.time-plan["times"][source])
    if difference>TIMING_TOLERANCE
        fail_timing!(app,sim,id,"指定時刻との不一致を検出しました";planned_at=plan["times"][source])
        return
    end
    plan["next_source"]=source+1
    if e["type"]!="job_completed"
        state["matched"]+=1;state["max_error_seconds"]=max(state["max_error_seconds"],difference)
        JS.record!(sim,"cyclic_transfer_matched";job=id,source_operation=source,planned_at=plan["times"][source],
            transporter="T$(plan["hoists"][source])",request_id=plan["request_id"],difference_seconds=difference)
    end
end

function clear_timing_pattern!(app)
    prior=app.timing_pattern
    if prior!==nothing
        for (id,plan) in prior["jobs"]
            job=get(app.sim.jobs,id,nothing)
            job!==nothing && unstarted_timed_job(job) && set_timed_durations!(job,plan["original_durations"];travel_before=get(plan,"original_travel_before",nothing))
        end
    end
    app.timing_pattern=nothing;app.sim.defer_zero_transfers=timing_enabled(app)
end

function timing_summary(app)
    state=app.timing_pattern
    next=nothing
    if state!==nothing
        for (id,plan) in state["jobs"]
            i=plan["next_source"];i>=length(plan["times"]) && continue
            at=plan["times"][i]
            if next===nothing || at<next["at"]
                next=Dict("job_id"=>id,"source_operation"=>i,"at"=>at,"transporter"=>"T$(plan["hoists"][i])")
            end
        end
    end
    Dict("mode"=>get(app.config["optimizer"],"transfer_execution","priority"),"active"=>state!==nothing,
        "period"=>state===nothing ? nothing : state["period"],"anchor"=>state===nothing ? nothing : state["anchor"],
        "matched_transfers"=>state===nothing ? 0 : state["matched"],"next_transfer"=>next,
        "max_error_seconds"=>state===nothing ? nothing : state["max_error_seconds"],"error"=>state===nothing ? nothing : state["error"])
end

function restore_timing_replay!(app,recording)
    timing_enabled(app) || return
    plans=Dict{String,Any}()
    for e in get(recording,"events",Any[])
        e["type"]=="cyclic_job_planned" || continue
        plan=deepcopy(e["plan"]);plan["next_source"]=1;plans[e["job"]]=plan
    end
    isempty(plans) && throw(ArgumentError("完全一致方式の再生には保存された搬送時刻が必要です"))
    plan=last(collect(values(plans)))
    app.timing_pattern=Dict{String,Any}("period"=>plan["period"],"anchor"=>0.0,"signature"=>"replay",
        "request_id"=>"replay","templates"=>Dict(),"jobs"=>plans,"next_slots"=>Dict(),"error"=>nothing,
        "matched"=>0,"max_error_seconds"=>0.0)
end
