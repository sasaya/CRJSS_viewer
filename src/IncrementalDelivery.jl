function prepare_pattern_entries(app,response)
    mapping,version=lock(app.mutex) do
        registered_mapping(app),(app.epoch,app.model_revision,length(app.mapping),length(app.sim.reserved_ids))
    end
    entries=extract_order(response["result"]["solution"],mapping)
    validate_entries(entries,mapping)
    (entries=entries,mapping=mapping,version=version)
end

stage_startup_pattern(app)=app.start_waiting && !app.sim.advance_enabled && isempty(app.sim.jobs)
function apply_pattern_result!(app,response,req;preserve_anchor=false,prepared=nothing,intermediate=false)
    if retain_better_pattern(app,response,req)
        best=app.best_cycle
        app.cached_cycle=merge(best,Dict("key"=>cycle_key(app),"revision"=>app.model_revision))
        needs_order=app.config["control"]["mode"] in ("optimized_priority","fixed_priority") && app.order_id===nothing
        !(intermediate && stage_startup_pattern(app)) && (app.reuse_pending || "job_added" in app.pending || needs_order ||
            (release_enabled(app) && app.release_pattern===nothing)) && reuse_cycle!(app)
        delete!(app.pending,"job_added")
        req["application"]="retained_better_pattern";req["applied_period"]=best["solution"]["T"]
        req["pattern_source_request_id"]=best["request_id"]
        note_conformance_reference!(app)
        return
    end
    cache_cycle!(app,response,req)
    req["applied_period"]=response["result"]["solution"]["T"]
    req["pattern_source_request_id"]=req["request_id"]
    if intermediate && stage_startup_pattern(app)
        # With no JOB admitted, ranks for thousands of future transfers cannot
        # affect dispatch. Preserve every verified cycle; expand once at finish.
        req["application"]="staged_until_start"
        note_conformance_reference!(app)
        return
    end
    current_version=(app.epoch,app.model_revision,length(app.mapping),length(app.sim.reserved_ids))
    if prepared!==nothing && prepared.version==current_version
        entries=prepared.entries
        current_req=merge(req,Dict("mapping"=>prepared.mapping))
    else
        current_req=merge(req,Dict("mapping"=>registered_mapping(app)))
        entries=extract_order(response["result"]["solution"],current_req["mapping"])
        validate_entries(entries,current_req["mapping"])
    end
    remaining=reconcile_order(app,entries,current_req)
    app.reuse_pending=false;delete!(app.pending,"job_added")
    previous_dispatch=dispatch_policy(app)
    if app.config["control"]["mode"] in ("optimized_priority","fixed_priority")
        install_release_pattern!(app,response["result"]["solution"],req;
            preserve_anchor=preserve_anchor || app.release_pattern!==nothing)
    end
    if JS.all_jobs_completed(app.sim)
        req["application"]="completed_run"
    elseif timing_failed(app)
        req["application"]="timing_stopped"
    elseif app.config["control"]["mode"] in ("optimized_priority","fixed_priority")
        apply_order!(app,remaining,req;previous=previous_dispatch)
    else
        req["application"]="compute_only"
    end
    note_conformance_reference!(app)
end

function receive_incumbent!(app,req,payload)
    # Verify before taking the simulator lock. Nothing in the payload can edit
    # in-flight machine occupancy, destination reservations or travel times.
    for key in ("request_id","experiment_epoch","problem_id","transport_count","model_revision")
        payload[key]==req[key] || throw(ArgumentError("改善解の要求情報が不一致です: $key"))
    end
    result=payload["result"]
    verification=SolverVerification.verify_result(SolverVerification.problem_from_dict(req["problem"]),result)
    verification["valid"] || throw(ArgumentError("改善解の数値検証が不合格です"))
    wanted=lock(app.mutex) do
        app.active===req && get(req["optimizer"],"pattern_delivery","final")=="incremental" &&
            req["experiment_epoch"]==app.epoch && req["model_revision"]==app.model_revision &&
            result["solution"]["T"]<get(req,"best_delivered_period",Inf)
    end
    wanted || return false
    response=Dict{String,Any}("status"=>"FEASIBLE","result"=>result)
    lightweight=lock(app.mutex) do;retain_better_pattern(app,response,req) || stage_startup_pattern(app);end
    prepared=lightweight ? nothing : prepare_pattern_entries(app,response)
    yield()
    lock(app.mutex) do
        app.active===req && get(req["optimizer"],"pattern_delivery","final")=="incremental" || return false
        sync_clock!(app)
        app.active===req && req["experiment_epoch"]==app.epoch && req["problem_id"]==app.problem_id &&
            req["transport_count"]==length(app.sim.transporters) && req["model_revision"]==app.model_revision || return false
        T=result["solution"]["T"]
        T<get(req,"best_delivered_period",Inf) || return false
        updates=get(req,"callback_updates",0)
        apply_pattern_result!(app,response,req;preserve_anchor=updates>0,prepared=prepared,intermediate=true)
        req["callback_updates"]=updates+1;req["best_delivered_period"]=T
        req["incumbent"]=Dict("index"=>payload["index"],"result"=>result,"simulation_time"=>app.sim.time,
            "application"=>req["application"],"order_id"=>app.order_id,"applied_period"=>get(req,"applied_period",T),
            "pattern_source_request_id"=>get(req,"pattern_source_request_id",req["request_id"]))
        get!(req,"deliveries",Any[])
        push!(req["deliveries"],Dict("index"=>payload["index"],"period"=>T,"simulation_time"=>app.sim.time,
            "order_id"=>app.order_id,"application"=>req["application"],"applied_period"=>get(req,"applied_period",T),
            "pattern_source_request_id"=>get(req,"pattern_source_request_id",req["request_id"])))
        JS.record!(app.sim,"optimizer_incumbent_received";request_id=req["request_id"],index=payload["index"],period=T,
            bound=result["solver_bound"],order_id=app.order_id,application=req["application"],applied_period=get(req,"applied_period",T))
        true
    end
end

function receive_pending_incumbents!(app,req,directory)
    get(req["optimizer"],"pattern_delivery","final")=="incremental" || return
    folder=joinpath(directory,"history","delivery");manifest=joinpath(folder,"index.json")
    isfile(manifest) || return
    # An atomic replace on Windows can briefly remove the old manifest.
    state=try;readjson(manifest);catch err;err isa SystemError || err isa Base.IOError ? nothing : rethrow();end
    state===nothing && return
    for index in get(req,"last_incumbent_index",0)+1:state["count"]
        payload=readjson(joinpath(folder,"update_$(lpad(index,6,'0')).json"))
        payload["index"]==index || throw(ArgumentError("改善解の更新番号が不一致です"))
        receive_incumbent!(app,req,payload)
        lock(app.mutex) do;req["last_incumbent_index"]=index;end
        yield()
    end
end
