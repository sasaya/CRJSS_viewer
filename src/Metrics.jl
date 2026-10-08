function statistics(values)
    v=sort(Float64.(values));isempty(v) && return Dict("count"=>0,"mean"=>0.0,"max"=>0.0,"p95"=>0.0)
    Dict("count"=>length(v),"mean"=>sum(v)/length(v),"max"=>last(v),"p95"=>v[clamp(ceil(Int,0.95length(v)),1,length(v))])
end
function metrics(app;include_cycle_history=true)
    sim=app.sim
    completed=[j for j in values(sim.jobs) if j.completed!==nothing]
    waits=[j.transport_waited+(j.transport_wait_start===nothing ? 0 : sim.time-j.transport_wait_start) for j in values(sim.jobs)]
    selections=[e for e in sim.log if e["type"]=="priority_selected"]
    by_rank=Dict("ranked"=>Float64[],"unranked"=>Float64[])
    started=[e for e in sim.log if e["type"]=="transfer_started"]
    selected=Dict{Tuple{String,Float64},Any}()
    requested=Dict{String,Vector{Float64}}()
    for e in selections
        id=replace(e["transfer_id"],r":\d+-\d+$"=>"")
        selected[(id,e["time"])]=e
    end
    for e in sim.log
        e["type"]=="transport_requested" || continue
        push!(get!(requested,e["job"],Float64[]),e["time"])
    end
    for e in started
        selection=get(selected,(e["job"],e["time"]),nothing)
        times=get(requested,e["job"],Float64[])
        request=searchsortedlast(times,e["time"])
        request==0 && continue
        group=selection===nothing || selection["rank"]===nothing ? "unranked" : "ranked"
        push!(by_rank[group],e["time"]-times[request])
    end
    Dict("cycle_conformance"=>cycle_conformance_summary(app;include_history=include_cycle_history),
        "observation_seconds"=>sim.time,"completed_jobs"=>length(completed),"unfinished_jobs"=>length(sim.reserved_ids)-length(completed),
        "all_completed_at"=>JS.all_jobs_completed(sim) && !isempty(completed) ? maximum(j.completed for j in completed) : nothing,
        "throughput"=>sim.time==0 ? 0.0 : length(completed)/sim.time,
        "flow_seconds"=>statistics([j.completed-j.entered for j in completed]),"job_transport_wait_seconds"=>statistics(waits),
        "requested_flow_seconds"=>statistics([j.completed-get(get(app.release_plans,j.id,Dict()),"requested_at",j.entered) for j in completed]),
        "admission_delay_seconds"=>statistics([(get(p,"actual_at",nothing)===nothing ? sim.time : p["actual_at"])-p["requested_at"] for p in values(app.release_plans)]),
        "transfer_wait_seconds"=>Dict(k=>statistics(v) for (k,v) in by_rank),
        "unranked_waiting"=>[Dict("job_id"=>id,"wait"=>sim.time-sim.jobs[id].transport_wait_start) for id in sim.transfer_queue
            if !haskey(app.ranks,transfer_id(id,sim.jobs[id].index-1))],
        "transfer_count"=>length(sim.transfers),"skip_count"=>sum(length(e["skipped"]) for e in selections;init=0),
        "transport_utilization"=>Dict(t.id=>sim.time==0 ? 0 : t.busy/sim.time for t in sim.transporters),
        "machines"=>Dict(id=>Dict("busy_seconds"=>m.busy,"down_seconds"=>m.downtime,"utilization"=>sim.time==0 ? 0 : m.busy/sim.time) for (id,m) in sim.machines),
        "optimizer_wall_seconds"=>statistics([r["total_wall_seconds"] for r in app.requests if haskey(r,"total_wall_seconds")]),
        "optimizer_outcomes"=>Dict(status=>count(r->r["status"]==status,app.requests) for status in unique([r["status"] for r in app.requests])),
        "optimizer_triggers"=>Dict(reason=>count(r->reason in r["reasons"],app.requests) for reason in unique([reason for r in app.requests for reason in r["reasons"]])),
        "tick_interval_seconds"=>statistics(app.tick_intervals),"http_seconds"=>statistics(app.http_times),
        "definitions"=>Dict("wait"=>"搬送要求から開始まで。ジョブ値は累積・未開始待ちを含む。", "utilization"=>"busy秒 / シミュレーション観測秒。回送は含まない。",
            "cycle"=>"最適化Tは参考値。実完了時刻・U上限順守を保証しない。"))
end
function gui_log_event(event)
    data=Dict(k=>k=="skipped" ? deepcopy(first(v,min(50,length(v)))) : deepcopy(v) for (k,v) in event)
    haskey(event,"skipped") && (data["skipped_count"]=length(event["skipped"]))
    data
end
function snapshot(app;view_window=nothing,include_transfer_order=true)
    cutoff=view_window===nothing || view_window==0 ? -Inf : max(0.0,app.sim.time-view_window)
    data=JS.snapshot(app.sim;history_since=cutoff)
    if view_window!==nothing && view_window>0
        # Keep chart markers and the latest selection explanations; the full
        # history remains available through /api/state and experiment export.
        first_operations=Dict{String,Any}();selected_indices=Int[]
        marker_types=("optimizer_started","optimizer_received","optimizer_incumbent_received","order_applied","dispatch_policy_changed","machine_failed","machine_repaired","cyclic_timing_missed")
        for (i,e) in enumerate(app.sim.log)
            e["type"]=="operation_started" && e["operation"]==1 && !haskey(first_operations,e["job"]) && (first_operations[e["job"]]=deepcopy(e))
            e["type"]=="priority_selected" && push!(selected_indices,i)
        end
        selection_tail=Set(last(selected_indices,min(30,length(selected_indices))))
        recent_start=max(1,length(app.sim.log)-199)
        data["log"]=[gui_log_event(e)
            for (i,e) in enumerate(app.sim.log) if i>=recent_start || i in selection_tail || (e["type"] in marker_types && e["time"]>=cutoff)]
        data["first_operations"]=first_operations
        data["history_window_seconds"]=view_window
    end
    data["running"]=app.running;data["speed"]=app.speed
    data["simulation_start"]=simulation_start_summary(app)
    data["completed"]=!isempty(app.sim.reserved_ids) && JS.all_jobs_completed(app.sim)
    data["optimizer"]=Dict("active"=>app.active===nothing ? nothing : Dict(k=>get(app.active,k,nothing) for k in
        ("request_id","status","reasons","started_wall","simulation_time")),"pending_reasons"=>sort(collect(app.pending)),
        "next_period"=>app.next_period,"order_id"=>app.order_id,"mode"=>app.config["control"]["mode"],
        "last_result"=>isempty(app.requests) ? nothing : Dict(k=>get(last(app.requests),k,nothing) for k in ("status","application","error","total_wall_seconds")))
    data["optimizer"]["active"]!==nothing && (data["optimizer"]["active"]["elapsed_wall_seconds"]=wall()-app.active["started_wall"])
    data["optimizer"]["calculation"]=calculation_summary(app)
    data["optimizer"]["reuse"]=reuse_summary(app)
    data["optimizer"]["timing"]=timing_summary(app)
    data["transfer_order"]=include_transfer_order ? [merge(copy(e),Dict("state"=>entry_state(app,e))) for e in app.entries] : Any[]
    data["transfer_order_included"]=include_transfer_order
    data["metrics"]=metrics(app;include_cycle_history=view_window===nothing||view_window==0)
    data["experiment_directory"]=app.directory
    data["job_release"]=Dict("enabled"=>release_enabled(app),"pattern"=>deepcopy(app.release_pattern),
        "waiting_count"=>count(j->j.status=="waiting_release",values(app.sim.jobs)),
        "plans"=>deepcopy(collect(values(app.release_plans))))
    next_release=findfirst(e->e.kind=="release_job",app.sim.events)
    data["job_release"]["next_release_at"]=next_release===nothing ? nothing : app.sim.events[next_release].at
    for job in data["jobs"]
        plan=get(app.release_plans,job["id"],nothing)
        job["requested_at"]=plan===nothing ? job["entered"] : plan["requested_at"]
        job["release_at"]=plan===nothing ? job["entered"] : plan["actual_at"]
        job["planned_release_at"]=plan===nothing ? nothing : plan["planned_at"]
    end
    data
end
function save_experiment!(app)
    # Capture immutable data under lock, serialize outside it.
    data=lock(app.mutex) do
        sync_clock!(app)
        Dict("config"=>deepcopy(app.config),"initial_config"=>deepcopy(app.initial_config),"final_state"=>snapshot(app),"metrics"=>metrics(app),
            "requests"=>[public_request(r) for r in app.requests],"orders"=>deepcopy(app.orders),
            "events"=>deepcopy(app.sim.log),"directory"=>app.directory)
    end
    dir=data["directory"]
    for key in ("config","final_state","metrics");writejson(joinpath(dir,key*".json"),data[key]);end
    for req in data["requests"];writejson(joinpath(dir,"requests",req["request_id"],"record.json"),req);end
    for order in data["orders"];writejson(joinpath(dir,"orders",order["order_id"]*".json"),order);end
    open(joinpath(dir,"events.jsonl"),"w") do io
        for event in data["events"];println(io,JSON3.write(event));end
    end
    replayconfig=deepcopy(data["initial_config"])
    # Replay actual observed faults, including random realizations and mode switches.
    faults=[Dict("type"=>e["type"]=="machine_failed" ? "fail_machine" : "repair_machine","machine"=>e["machine"],"at"=>e["time"])
        for e in data["events"] if e["type"] in ("machine_failed","machine_repaired")]
    replayconfig["faults"]=Dict("mode"=>"scenario","events"=>faults)
    replayconfig["events"]=[deepcopy(e) for e in get(data["config"],"events",Any[]) if e["type"]=="add_job"]
    actions=[deepcopy(e) for e in data["events"] if e["type"] in ("transport_count_changed","optimizer_mode_changed","transfer_execution_changed")]
    writejson(joinpath(dir,"replay.json"),Dict("config"=>replayconfig,"orders"=>data["orders"],"events"=>data["events"],
        "release_plans"=>data["final_state"]["job_release"]["plans"],"transporter_actions"=>actions))
    data
end
