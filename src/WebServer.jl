response(status,data)=JS.json_response(status,data)
# HTTP's default adapter handles reset/broken-pipe errors, but omits Windows
# ECANCELED. Catch transport errors at the read/write boundary only: failures
# in the application handler must keep their normal error reporting.
client_disconnected(err)=err isa Base.IOError && err.code in
    (Base.UV_ECANCELED,Base.UV_EPIPE,Base.UV_ECONNRESET,Base.UV_ECONNABORTED)
function connection_io(f,stream)
    try
        f()
        true
    catch err
        client_disconnected(err) || rethrow()
        close(stream)
        @debug "Client disconnected during HTTP transfer" exception=err
        false
    end
end
function resilient_stream_handler(handler)
    return function(stream)
        request=stream.message
        received=connection_io(stream) do
            request.body=read(stream)
            HTTP.closeread(stream)
        end
        received || return nothing
        result=handler(request)
        request.response=result;result.request=request
        connection_io(stream) do
            HTTP.startwrite(stream)
            write(stream,result.body)
            # Finish chunk framing and pending socket writes while still inside
            # the transport boundary. Leave closewrite to the HTTP server.
            HTTP.closebody(stream)
            flush(stream.stream)
        end
        nothing
    end
end
function replace_application!(app,config)
    config,problem,mapping=prepare_config(config)
    sim=JS.load_config(config;advance_enabled=config["optimizer"]["simulation_start_mode"]!="after_optimization")
    cancel!(app;reason="reset")
    # Each reset/config replacement starts a new experiment directory; save the preceding run first in the API.
    app.epoch+=1;app.sim=sim;app.config=config;app.problem=problem
    app.problem_id=problem===nothing ? nothing : problem_hash(problem);app.mapping=mapping
    empty!(app.ranks);empty!(app.entries);empty!(app.orders);empty!(app.requests);empty!(app.replay)
    empty!(app.transfer_tokens);empty!(app.shared_entries)
    empty!(app.replay_actions);app.replay_mode=false;app.initial_config=deepcopy(config)
    app.release_pattern=nothing;app.timing_pattern=nothing;empty!(app.release_plans)
    app.cycle_conformance=CycleConformance();empty!(app.replay_cycle_references)
    empty!(app.replay_releases)
    app.cached_cycle=nothing;app.best_cycle=nothing;app.reuse_pending=false;app.reuse_count=0;app.last_reuse_at=nothing
    app.scenario_signature=nothing;app.last_external_route=nothing;app.start_count=0;app.model_revision=0
    initialize_scenario_signature!(app)
    app.order_id=nothing;app.fixed_ready=false;app.running=false;app.last_wall=wall()
    app.start_waiting=false;app.startup_error=nothing
    app.next_period=config["optimizer"]["period_sim_seconds"]
    app.directory=joinpath(ROOT,"results",Dates.format(now(),"yyyymmdd_HHMMSS")*"_"*string(uuid4()))
    mkpath(app.directory);writejson(joinpath(app.directory,"config.json"),config)
    write_metadata(app)
    attach!(app)
end
function handle_request(app,req)
    started=wall();path=first(split(req.target,'?'))
    try
        if req.method=="GET" && path=="/"
            return HTTP.Response(200,["Content-Type"=>"text/html; charset=utf-8","Cache-Control"=>"no-store"],read(joinpath(ROOT,"web","index.html"),String))
        elseif req.method=="GET" && path=="/assets/optimization-history.js"
            return HTTP.Response(200,["Content-Type"=>"text/javascript; charset=utf-8","Cache-Control"=>"no-store"],read(joinpath(ROOT,"web","optimization-history.js"),String))
        elseif req.method=="GET" && path=="/api/result"
            return response(200,save_experiment!(app))
        elseif req.method=="GET" && path in ("/api/optimizer/history","/api/optimizer/frame")
            return optimization_history_response(app,req,path)
        elseif req.method=="GET"
            status,payload=lock(app.mutex) do
                sync_clock!(app)
                if path=="/api/state";(200,snapshot(app))
                elseif path=="/api/view"
                    params=HTTP.URIs.queryparams(HTTP.URI(req.target))
                    seconds=JS.number(parse(Float64,get(params,"window","60")),"window")
                    seconds>=0 || throw(ArgumentError("window は0以上です"))
                    (200,snapshot(app;view_window=seconds,include_transfer_order=get(params,"order","1")!="0"))
                elseif path=="/api/session";(200,Dict("state"=>snapshot(app),"config"=>deepcopy(app.config),"optimizer"=>optimizer_status(app;compact=true)))
                elseif path=="/api/gui-session"
                    config=Dict(k=>deepcopy(app.config[k]) for k in ("control","optimizer","clock","input_info","import_options","faults") if haskey(app.config,k))
                    (200,Dict("state"=>snapshot(app;view_window=60),"config"=>config,"config_compact"=>true,"optimizer"=>optimizer_status(app;compact=true)))
                elseif path=="/api/config";(200,deepcopy(app.config))
                elseif path=="/api/optimizer/status";(200,optimizer_status(app))
                elseif path=="/api/optimizer/summary";(200,optimizer_status(app;compact=true))
                elseif path=="/api/metrics";(200,metrics(app))
                elseif path=="/api/transfer-order";(200,Dict("order_id"=>app.order_id,
                    "entries"=>snapshot(app)["transfer_order"],"history"=>deepcopy(app.orders),
                    "selections"=>[e for e in app.sim.log if e["type"]=="priority_selected"]))
                else;(404,Dict("error"=>"エンドポイントが見つかりません"));end
            end
            # JSON serialization must not delay the simulation ticker or buttons.
            return response(status,payload)
        elseif req.method=="POST"
            data=JS.parse_body(req)
            if path=="/api/config" || path=="/api/config/file"
                if path=="/api/config/file"
                    raw=read_input_json(data["path"])
                    raw["import_options"]=get(data,"import_options",get(raw,"import_options",Dict()))
                    data=raw
                end
                prepared=prepare_config(data)[1];JS.load_config(prepared)
                save_experiment!(app)
                return lock(app.mutex) do
                    replace_application!(app,prepared);response(200,snapshot(app))
                end
            elseif path=="/api/replay"
                recording=read_input_json(JS.required(data,"path"))
                config=prepare_config(recording["config"])[1];JS.load_config(config)
                orders=deepcopy(get(recording,"orders",Any[]))
                mapping=prepare_config(config)[3]
                for order in orders
                    tokens=Set{String}()
                    for e in order["entries"]
                        haskey(mapping,e["job_id"]) && e["transfer_id"]==transfer_id(e["job_id"],e["source_operation"]) &&
                            1<=e["source_operation"]<mapping[e["job_id"]]["operation_count"] || throw(ArgumentError("再生順位と経路が不一致です"))
                        e["transfer_id"] in tokens && throw(ArgumentError("再生順位に重複があります"))
                        push!(tokens,e["transfer_id"])
                    end
                    JS.number(order["applied_at"],"applied_at")
                end
                save_experiment!(app)
                return lock(app.mutex) do
                    replace_application!(app,config);app.replay_mode=true
                    # Reproduce the actual admission times, including early release
                    # when cycle adjustment was disabled during the original run.
                    for event in get(recording,"events",Any[])
                        if event["type"] in ("job_release_planned","job_release_rescheduled") && haskey(event,"job")
                            app.replay_releases[event["job"]]=Dict("at"=>event["planned_at"],"request_id"=>get(event,"request_id",nothing))
                        elseif event["type"]=="job_released" && haskey(app.replay_releases,event["job"])
                            app.replay_releases[event["job"]]["at"]=event["time"]
                        end
                    end
                    for plan in get(recording,"release_plans",Any[])
                        at=get(plan,"actual_at",nothing)===nothing ? plan["planned_at"] : plan["actual_at"]
                        app.replay_releases[plan["job_id"]]=Dict("at"=>at,"request_id"=>get(plan,"request_id",nothing))
                    end
                    if !isempty(app.replay_releases)
                        # Install admission pacing before time-zero jobs dispatch.
                        app.sim=JS.load_config(config;advance_enabled=false,event_observer=(sim,event)->begin
                            if event["type"]=="job_added" && haskey(app.replay_releases,event["job"])
                                plan=app.replay_releases[event["job"]]
                                defer_job_release!(app,event["job"],plan["at"];request_id=plan["request_id"],sim)
                            elseif event["type"]=="job_released" && haskey(app.release_plans,event["job"])
                                app.release_plans[event["job"]]["actual_at"]=sim.time
                            end
                        end)
                        attach!(app)
                    end
                    app.replay=sort!(orders;by=o->o["applied_at"])
                    app.replay_actions=sort!(deepcopy(get(recording,"transporter_actions",Any[]));by=a->a["time"])
                    app.replay_cycle_references=sort!([deepcopy(e) for e in get(recording,"events",Any[]) if e["type"]=="cycle_reference_changed"];by=e->e["time"])
                    restore_timing_replay!(app,recording)
                    app.sim.advance_enabled=true
                    JS.advance!(app.sim,app.sim.time)
                    response(200,snapshot(app))
                end
            elseif path=="/api/scenarios/preview"
                source=input_path(data["path"])
                raw=read_input_json(source);raw["import_options"]=get(data,"import_options",get(raw,"import_options",Dict()));raw["faults"]=Dict("mode"=>"none")
                config=prepare_config(raw)[1]
                config["input_info"]["source_file"]=source
                return response(200,Dict("config"=>config,"preview"=>JS.snapshot(JS.load_config(config))))
            elseif path=="/api/scenarios/sequence/preview"
                configs=Any[]
                for e in data["entries"]
                    raw=haskey(e,"path") ? read_input_json(e["path"]) : deepcopy(e["config"])
                    haskey(raw,"W") && (raw["import_options"]=get(data,"import_options",get(raw,"import_options",Dict())))
                    push!(configs,prepare_config(raw)[1])
                end
                isempty(configs) && throw(ArgumentError("シナリオを指定してください"))
                catalog,route_maps=sequence_problem_catalog(configs)
                catalog_id=problem_hash(catalog)
                sequence=JS.build_sequence_config(configs;mode=get(data,"mode","completion_or_time"),interval=get(data,"interval",60),count=get(data,"transport_count",1))
                instances=Dict{Int,Int}()
                for (i,c) in enumerate(configs), (j,definition) in enumerate(c["jobs"])
                    m=deepcopy(definition["provenance"]);id=sequence["scenario_sequence"][i]["jobs"][j]["id"]
                    m["job_id"]=id;m["scenario_id"]="S$i";m["problem_id"]=catalog_id
                    m["route_id"]=route_maps[i][m["route_id"]]
                    instances[m["route_id"]]=get(instances,m["route_id"],0)+1
                    m["instance_index"]=instances[m["route_id"]]
                    sequence["scenario_sequence"][i]["jobs"][j]["provenance"]=m
                end
                sequence["source_problem"]=catalog
                current_optimizer,current_control=lock(app.mutex) do
                    deepcopy(app.config["optimizer"]),deepcopy(app.config["control"])
                end
                sequence["optimizer"]=normalize_optimizer(merge(current_optimizer,get(data,"optimizer",Dict())))
                sequence["control"]=normalize_control(merge(current_control,get(data,"control",Dict())))
                sequence["import_options"]=get(first(configs),"import_options",Dict())
                return response(200,Dict("config"=>sequence,"preview"=>JS.snapshot(JS.load_config(sequence))))
            elseif path=="/api/control" && get(data,"action","")=="reset"
                save_experiment!(app)
                return lock(app.mutex) do
                    replace_application!(app,app.config);response(200,snapshot(app))
                end
            end
            return lock(app.mutex) do
                sync_clock!(app)
                sim=app.sim
                if path=="/api/control"
                    action=JS.required(data,"action")
                    if action=="start"
                        timing_failed(app) && return response(409,Dict("error"=>"指定搬送時刻を実行できず停止しています。順位のみ方式へ切り替えるか、完全一致方式で初期設定に戻して再実行してください。"))
                        if !app.running && !app.start_waiting && !JS.all_jobs_completed(sim)
                            begin_start!(app)
                        end
                    elseif action=="pause"
                        app.running=false
                        app.start_waiting && JS.record!(sim,"simulation_start_paused")
                        app.start_waiting=false
                    elseif action=="speed"
                        app.speed=JS.number(JS.required(data,"speed"),"speed";positive=true)
                        JS.record!(sim,"clock_speed_changed";speed=app.speed)
                    elseif action=="step"
                        timing_failed(app) && return response(409,Dict("error"=>"完全一致方式の時刻不一致で停止しています。順位のみ方式へ切り替えるか、初期設定に戻してください。"))
                        app.running && return response(409,Dict("error"=>"一時停止中にステップ実行してください"))
                        !sim.advance_enabled && return response(409,Dict("error"=>"計算完了後に開始するモードでは、結果適用までJOB投入・時計の進行を保留します"))
                        advance_app!(app,sim.time+JS.number(JS.required(data,"seconds"),"seconds";positive=true))
                    else;throw(ArgumentError("未知の操作"));end
                    app.last_wall=wall();launch_pending!(app);response(200,snapshot(app))
                elseif path=="/api/input"
                    if get(data,"type","")=="add_job" && haskey(data["job"],"route_id")
                        data["job"]=route_job(app,data["job"])
                    elseif get(data,"type","")=="add_job"
                        # Arbitrary operations cannot claim provenance without route validation.
                        pop!(data["job"],"provenance",nothing)
                    end
                    accepted=JS.submit!(sim,data;settle=false)
                    if data["type"]=="add_job"
                        job=data["job"]
                        haskey(job,"provenance") && (app.mapping[job["id"]]=deepcopy(job["provenance"]))
                        # Arrival observer decides reuse versus recalculation.
                        # Save external additions with their actual absolute release times for replay/reset.
                        get!(app.config,"events",Any[])
                        push!(app.config["events"],merge(deepcopy(data),Dict("at"=>accepted["at"])))
                    else
                        push!(get!(app.config,"events",Any[]),merge(deepcopy(data),Dict("at"=>accepted["at"])))
                    end
                    JS.advance!(sim,sim.time);launch_pending!(app)
                    response(200,Dict("accepted"=>accepted,"state"=>snapshot(app)))
                elseif path=="/api/faults"
                    JS.configure_faults!(sim,data);app.config["faults"]=deepcopy(sim.faults)
                    trigger!(app,"fault_mode_changed");launch_pending!(app);response(200,snapshot(app))
                elseif path=="/api/transporters"
                    count=JS.transport_count(JS.required(data,"count"))
                    timing_enabled(app) && any(j->j.status!="completed"&&!unstarted_timed_job(j),values(sim.jobs)) && throw(ArgumentError("完全一致方式では着手済みJOBの完了後に搬送台数を変更してください"))
                    try;JS.configure_transporters!(sim,count)
                    catch err;err isa ArgumentError && return response(409,Dict("error"=>err.msg));rethrow();end
                    app.config["transport_count"]=count
                    app.config["import_options"]=merge(get(app.config,"import_options",Dict()),Dict("transport_count"=>count))
                    clear_release_pattern!(app)
                    trigger!(app,"transport_count_changed");launch_pending!(app);response(200,snapshot(app))
                elseif path=="/api/optimizer/run"
                    id=request!(app);response(202,Dict("request_id"=>id,"queued"=>!isempty(app.pending)))
                elseif path=="/api/optimizer/cancel"
                    if haskey(data,"request_id") && data["request_id"]==pending_request_id(app)
                        if app.active===nothing
                            cancel!(app)
                        else
                            empty!(app.pending)
                        end
                        return response(200,optimizer_status(app))
                    end
                    if haskey(data,"request_id") && (app.active===nothing || app.active["request_id"]!=data["request_id"])
                        known=any(r->r["request_id"]==data["request_id"],app.requests)
                        return response(known ? 409 : 404,Dict("error"=>known ? "その要求は実行中ではありません" : "要求IDが見つかりません"))
                    end
                    cancel!(app;request_id=get(data,"request_id",nothing));response(200,optimizer_status(app))
                elseif path=="/api/optimizer/config"
                    # Search settings preserve the running engine and sequence.
                    # Only an untouched time-zero experiment can be restaged
                    # when its startup choice changes.
                    requested=get(data,"optimizer",Dict())
                    requested isa AbstractDict || throw(ArgumentError("optimizer はJSONオブジェクトです"))
                    optimizer=normalize_optimizer(merge(app.config["optimizer"],requested))
                    optimizer["simulation_start_mode"]=="after_optimization" && app.problem===nothing && throw(ArgumentError("計算完了後に開始するには、最適化原入力W/R/N/V/L/Uを持つシナリオが必要です"))
                    control=normalize_control(merge(app.config["control"],haskey(data,"mode") ? Dict("mode"=>data["mode"]) : Dict()))
                    timing_changed=optimizer["transfer_execution"]!=app.config["optimizer"]["transfer_execution"]
                    if optimizer["transfer_execution"]=="cyclic_timing"
                        app.problem===nothing && throw(ArgumentError("完全一致方式には最適化原入力W/R/N/V/L/Uが必要です"))
                        control["mode"] in ("optimized_priority","fixed_priority") || throw(ArgumentError("完全一致方式はオンライン優先順位または固定優先順位で使用してください"))
                        fresh=app.start_count==0 && sim.time==0 && !app.running
                        timing_changed && !fresh && any(j->j.status!="completed"&&!unstarted_timed_job(j),values(sim.jobs)) && throw(ArgumentError("完全一致方式はJOB着手前に設定してください。実行中の実験を保存し、初期設定に戻してから選択してください。"))
                    end
                    mode_changed=control["mode"]!=app.config["control"]["mode"]
                    release_changed=optimizer["delay_job_release"]!=app.config["optimizer"]["delay_job_release"]
                    schedule_only=control==app.config["control"] && all(
                        get(optimizer,key,nothing)==get(app.config["optimizer"],key,nothing)
                        for key in union(keys(optimizer),keys(app.config["optimizer"]))
                        if key ∉ ("recalculation_mode","period_sim_seconds","simulation_start_mode"))
                    previous=dispatch_policy(app)
                    previous_start_mode=app.config["optimizer"]["simulation_start_mode"]
                    app.config["control"]=control;app.config["optimizer"]=optimizer
                    if app.start_count==0 && sim.time==0
                        app.initial_config["optimizer"]=deepcopy(optimizer)
                        app.initial_config["control"]=deepcopy(control)
                    end
                    configure_simulation_start!(app,previous_start_mode)
                    sim=app.sim
                    app.next_period=sim.time+app.config["optimizer"]["period_sim_seconds"]
                    if schedule_only
                        app.config["optimizer"]["recalculation_mode"]=="events" && delete!(app.pending,"periodic")
                        JS.record!(sim,"recalculation_mode_changed";mode=app.config["optimizer"]["recalculation_mode"])
                        return response(200,snapshot(app))
                    end
                    # Preserve the active ranks and published admissions while
                    # re-solving. Explicit dispatch/release policy changes still
                    # use their existing semantics, without resetting scenarios.
                    (mode_changed || release_changed || timing_changed) && clear_release_pattern!(app)
                    sim.defer_zero_transfers=timing_enabled(app)
                    timing_changed && JS.record!(sim,"transfer_execution_changed";mode=optimizer["transfer_execution"])
                    timing_changed && record_dispatch_switch!(app,previous;reason="transfer_execution_changed")
                    app.next_period=sim.time+app.config["optimizer"]["period_sim_seconds"]
                    if mode_changed
                        empty!(app.ranks);empty!(app.entries);app.order_id=nothing;app.fixed_ready=false
                        JS.record!(sim,"optimizer_mode_changed";mode=control["mode"])
                        record_dispatch_switch!(app,previous;reason="settings_changed")
                    else
                        JS.record!(sim,"optimizer_settings_changed";solver=optimizer["solver"],pattern_delivery=optimizer["pattern_delivery"],stop_condition=optimizer["stop_condition"])
                    end
                    cancel!(app;reason="settings_changed");trigger!(app,"settings_changed");launch_pending!(app)
                    response(200,snapshot(app))
                else;response(404,Dict("error"=>"エンドポイントが見つかりません"));end
            end
        end
        response(404,Dict("error"=>"エンドポイントが見つかりません"))
    catch err
        if err isa ArgumentError || err isa KeyError
            message=err isa ArgumentError && err.msg=="このソルバーでは対応していません" ? err.msg : sprint(showerror,err)
            return response(400,Dict("error"=>message))
        end
        @error "API error" exception=(err,catch_backtrace())
        response(500,Dict("error"=>sprint(showerror,err)))
    finally
        lock(app.mutex) do
            push!(app.http_times,wall()-started)
        end
    end
end
function start_server(config;host="127.0.0.1",port=8081,autostart=false)
    input=config isa AbstractString ? readjson(config) : config
    app=Application(input)
    app.server=HTTP.serve!(resilient_stream_handler(req->handle_request(app,req)),host,port;stream=true,verbose=false,listenany=port==0)
    if autostart && !JS.all_jobs_completed(app.sim)
        begin_start!(app)
    end
    if !autostart && app.config["optimizer"]["warmup"] && app.problem!==nothing && app.config["control"]["mode"]!="fifo"
        request!(app,"warmup")
    end
    app.last_wall=wall()
    app.ticker=@async begin
        try
            previous=wall()
            while !app.stopped
                sleep(0.02)
                lock(app.mutex) do
                    current=wall();push!(app.tick_intervals,current-previous);previous=current
                    sync_clock!(app);launch_pending!(app)
                end
            end
        catch err
            app.running=false
            @error "Clock driver failed" exception=(err,catch_backtrace())
        end
    end
    app
end
function stop_server!(app)
    lock(app.mutex) do
        sync_clock!(app);app.stopped=true;app.running=false;cancel!(app;reason="shutdown")
    end
    app.server!==nothing && close(app.server)
    app.ticker!==nothing && wait(app.ticker)
    for req in app.requests
        task=get(req,"task",nothing);task!==nothing && wait(task)
    end
    save_experiment!(app)
    nothing
end
