# Periodic optimization is independent of the finite list of real JOB IDs.
cycle_key(app)=problem_hash(Dict("problem_id"=>app.problem_id,"transport_count"=>length(app.sim.transporters),
    "upper"=>app.config["optimizer"]["upper"],"solver"=>app.config["optimizer"]["solver"],
    "processing"=>get(get(app.config,"import_options",Dict()),"processing_time","lower")))
reusable_cycle(app)=app.cached_cycle!==nothing && app.cached_cycle["key"]==cycle_key(app) &&
    app.cached_cycle["revision"]==app.model_revision
# Search settings do not change the model. A fresh solve still runs, but its
# early incumbents must not replace an already verified shorter cycle.
pattern_model_key(app)=problem_hash(Dict("problem_id"=>app.problem_id,"transport_count"=>length(app.sim.transporters),
    "upper"=>app.config["optimizer"]["upper"],
    "processing"=>get(get(app.config,"import_options",Dict()),"processing_time","lower")))
function retain_better_pattern(app,response,req)
    best=app.best_cycle
    best!==nothing && best["model_key"]==pattern_model_key(app) &&
        get(req,"experiment_epoch",-1)==app.epoch && get(req,"problem_id",nothing)==app.problem_id &&
        get(req,"transport_count",0)==length(app.sim.transporters) &&
        get(req,"model_revision",-1)==app.model_revision && get(req,"cycle_key",nothing)==cycle_key(app) &&
        best["solution"]["T"]<response["result"]["solution"]["T"]
end
function invalidate_cycle!(app)
    app.model_revision+=1;app.cached_cycle=nothing;app.reuse_pending=false
end
function cache_cycle!(app,result,req)
    get(req,"cycle_key",nothing)==cycle_key(app) && get(req,"model_revision",-1)==app.model_revision || return
    app.cached_cycle=Dict("key"=>req["cycle_key"],"revision"=>app.model_revision,
        "model_key"=>pattern_model_key(app),
        "solution"=>deepcopy(result["result"]["solution"]),"status"=>result["status"],
        "request_id"=>req["request_id"],"solver"=>req["optimizer"]["solver"])
    if app.best_cycle===nothing || app.best_cycle["model_key"]!=pattern_model_key(app) ||
        result["result"]["solution"]["T"]<=app.best_cycle["solution"]["T"]
        app.best_cycle=app.cached_cycle
    end
end
function reuse_cycle!(app)
    reusable_cycle(app) || return
    timing_failed(app) && return
    cycle=app.cached_cycle;mapping=registered_mapping(app)
    entries=extract_order(cycle["solution"],mapping);validate_entries(entries,mapping)
    req=Dict{String,Any}("request_id"=>cycle["request_id"],"experiment_epoch"=>app.epoch,
        "problem_id"=>app.problem_id,"transport_count"=>length(app.sim.transporters),"mapping"=>mapping)
    remaining=reconcile_order(app,entries,req)
    previous=dispatch_policy(app)
    if app.config["control"]["mode"] in ("optimized_priority","fixed_priority")
        # Reuse leaves the period anchor and all published admission slots intact.
        app.release_pattern===nothing && install_release_pattern!(app,cycle["solution"],req)
        for m in sort(mapping;by=m->(m["route_id"],m["instance_index"]))
            plan_job_release!(app,m["job_id"])
        end
        if !JS.all_jobs_completed(app.sim)
            apply_order!(app,remaining,req;previous)
            last(app.orders)["reused_cycle"]=true
        end
    end
    app.reuse_count+=1;app.last_reuse_at=app.sim.time;app.reuse_pending=false
    JS.record!(app.sim,"optimizer_reused";request_id=cycle["request_id"],period=cycle["solution"]["T"],
        status=cycle["status"],reuse_count=app.reuse_count)
    note_conformance_reference!(app)
end
function scenario_fingerprint(app,scenario)
    function definition(job)
        state=app.timing_pattern
        # Execution phases do not change the scenario's input definition.
        durations=state===nothing ? nothing : get(get(state,"original_durations",Dict()),job.id,nothing)
        travel=state===nothing ? nothing : get(get(state,"original_travel_before",Dict()),job.id,nothing)
        Dict("route"=>get(get(app.mapping,job.id,Dict()),"route_id",nothing),
            "operations"=>[Dict("machine"=>op.machine,"duration"=>durations===nothing ? op.duration : durations[i],"members"=>op.members,
                "travel_before"=>travel===nothing ? op.travel_before : travel[i],"travel_times"=>op.travel_times) for (i,op) in enumerate(job.operations)])
    end
    canonical(sort([canonical(definition(pair[1])) for pair in scenario["prepared"]]))
end
function initialize_scenario_signature!(app)
    for scenario in app.sim.scenario_sequence
        scenario["started"]===nothing && continue
        app.scenario_signature=scenario_fingerprint(app,scenario)
    end
    for id in app.sim.job_order
        haskey(app.mapping,id) && (app.last_external_route=app.mapping[id]["route_id"])
    end
end
function scenario_changed!(app,id)
    scenario=only(filter(s->s["id"]==id,app.sim.scenario_sequence))
    signature=scenario_fingerprint(app,scenario)
    if app.scenario_signature!==nothing && signature!=app.scenario_signature
        trigger!(app,"scenario_changed")
    elseif reusable_cycle(app)
        app.reuse_pending=true
    end
    app.scenario_signature=signature
end
function external_route_changed!(app,id)
    route=get(get(app.mapping,id,Dict()),"route_id",nothing)
    # An unprovenanced custom route must not silently receive a cached order.
    if route===nothing || (app.last_external_route!==nothing && route!=app.last_external_route)
        trigger!(app,"route_changed")
    end
    app.last_external_route=route
end
function begin_start!(app)
    app.start_waiting && return
    if app.replay_mode
        app.sim.advance_enabled=true;app.running=true
        return
    end
    waiting=app.config["optimizer"]["simulation_start_mode"]=="after_optimization"
    waiting && app.problem===nothing && throw(ArgumentError("計算完了後に開始するには、最適化原入力W/R/N/V/L/Uを持つシナリオが必要です"))
    # A warm-up solve or a solve from the previous start does not count as this
    # start's mandatory fresh solve. Keep in-flight simulation state untouched.
    pending=copy(app.pending);app.active!==nothing && cancel!(app;reason="restart_calculation")
    union!(app.pending,pending);invalidate_cycle!(app);app.start_count+=1
    app.problem!==nothing && push!(app.pending,"start")
    app.start_waiting=waiting;app.startup_error=nothing
    app.sim.advance_enabled=!waiting;app.running=!waiting;app.last_wall=wall()
    if waiting
        JS.record!(app.sim,"simulation_start_waiting";start_count=app.start_count)
    else
        JS.record!(app.sim,"simulation_started";start_count=app.start_count,mode="parallel")
        JS.advance!(app.sim,app.sim.time)
    end
end
function reuse_summary(app)
    cycle=app.cached_cycle
    Dict("recalculation_mode"=>app.config["optimizer"]["recalculation_mode"],
        "state"=>app.replay_mode ? "replay" : app.problem===nothing ? "unavailable" : app.active!==nothing ? "computing" : reusable_cycle(app) ? "reusing" : "needs_solve",
        "reuse_count"=>app.reuse_count,"last_reuse_at"=>app.last_reuse_at,"start_count"=>app.start_count,
        "source_request_id"=>cycle===nothing ? nothing : cycle["request_id"],
        "source_solver"=>cycle===nothing ? nothing : cycle["solver"],
        "source_status"=>cycle===nothing ? nothing : cycle["status"])
end
