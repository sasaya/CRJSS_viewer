# The admission gate also protects time-zero arrivals from configuration,
# faults, external input and cycle updates while the startup solve is pending.
function finish_simulation_start!(app,req)
    app.start_waiting || return
    if req["status"] in ("OPTIMAL","FEASIBLE") && get(req,"application",nothing) in ("applied","compute_only","retained_better_pattern") &&
        req["start_count"]==app.start_count && req["model_revision"]==app.model_revision && reusable_cycle(app)
        app.start_waiting=false;app.startup_error=nothing
        app.sim.advance_enabled=true;app.running=true;app.last_wall=wall()
        JS.record!(app.sim,"simulation_started";mode="after_optimization",request_id=req["request_id"],
            period=get(req,"applied_period",req["result"]["result"]["solution"]["T"]),status=req["status"],start_count=app.start_count)
        # Pattern, ranks and release phases are already installed. The arrival
        # observer can now pace the very first JOB before dispatching it.
        JS.advance!(app.sim,app.sim.time)
    elseif isempty(app.pending)
        app.start_waiting=false
        app.startup_error="計算結果を適用できないため開始を保留しました（$(req["status"])）。"*
            string(get(req,"rejection_reason",get(req,"error","条件を確認して「開始 / 再開」で再試行してください。")))
        JS.record!(app.sim,"simulation_start_failed";request_id=req["request_id"],status=req["status"],error=app.startup_error)
    end
end

function configure_simulation_start!(app,previous)
    mode=app.config["optimizer"]["simulation_start_mode"]
    mode==previous && return
    if app.start_count==0 && app.sim.time==0 && !app.running && !app.replay_mode
        # Changing the startup choice on a freshly loaded experiment must undo
        # the legacy eager time-zero admission, without replacing its JOB IDs.
        log=[e for e in app.sim.log if startswith(e["type"],"optimizer_")]
        app.sim=JS.load_config(app.config;advance_enabled=mode!="after_optimization")
        app.cycle_conformance=CycleConformance();empty!(app.replay_cycle_references)
        append!(app.sim.log,log)
        empty!(app.ranks);empty!(app.entries);empty!(app.release_plans)
        app.order_id=nothing;app.fixed_ready=false;app.release_pattern=nothing;app.timing_pattern=nothing
        app.scenario_signature=nothing;app.last_external_route=nothing
        initialize_scenario_signature!(app);attach!(app)
        app.initial_config["optimizer"]["simulation_start_mode"]=mode
    elseif mode=="parallel" && !app.sim.advance_enabled
        app.sim.advance_enabled=true
        app.running=app.start_waiting
        app.start_waiting=false;app.startup_error=nothing;app.last_wall=wall()
        app.running && JS.record!(app.sim,"simulation_started";mode="parallel",reason="startup_mode_changed",start_count=app.start_count)
        JS.advance!(app.sim,app.sim.time)
    end
    JS.record!(app.sim,"simulation_start_mode_changed";mode)
end

simulation_start_summary(app)=Dict("mode"=>app.config["optimizer"]["simulation_start_mode"],
    "waiting"=>app.start_waiting,"admission_blocked"=>!app.sim.advance_enabled,"error"=>app.startup_error,
    "request_id"=>app.start_waiting && app.active!==nothing ? app.active["request_id"] : nothing)
