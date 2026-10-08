# Applied orders are immutable records. Share unchanged rows across improvement
# histories instead of cloning thousands of mutable dictionaries for each solve.
struct TransferEntry <: AbstractDict{String,Any}
    rank::Int
    transfer_id::String
    job_id::String
    source_operation::Int
end
const TRANSFER_ENTRY_KEYS=("rank","transfer_id","job_id","source_operation")
Base.length(::TransferEntry)=4
Base.keys(::TransferEntry)=TRANSFER_ENTRY_KEYS
Base.haskey(::TransferEntry,key)=key in TRANSFER_ENTRY_KEYS
Base.getindex(entry::TransferEntry,key::String)=key in TRANSFER_ENTRY_KEYS ? getfield(entry,Symbol(key)) : throw(KeyError(key))
Base.get(entry::TransferEntry,key,default)=haskey(entry,key) ? entry[key] : default
Base.iterate(entry::TransferEntry,state=1)=state>4 ? nothing : (TRANSFER_ENTRY_KEYS[state]=>entry[TRANSFER_ENTRY_KEYS[state]],state+1)
Base.copy(entry::TransferEntry)=Dict{String,Any}(entry)

Base.@kwdef mutable struct Application
    sim::JS.Simulation
    config::Dict{String,Any}
    problem::Any=nothing
    problem_id::Any=nothing
    mapping::Dict{String,Any}=Dict{String,Any}()
    ranks::Dict{String,Int}=Dict{String,Int}()
    entries::Vector{Any}=Any[]
    order_id::Any=nothing
    orders::Vector{Any}=Any[]
    transfer_tokens::Dict{String,String}=Dict{String,String}()
    shared_entries::Dict{String,TransferEntry}=Dict{String,TransferEntry}()
    requests::Vector{Any}=Any[]
    active::Any=nothing
    pending::Set{String}=Set{String}()
    epoch::Int=1
    running::Bool=false
    start_waiting::Bool=false
    startup_error::Any=nothing
    speed::Float64=1.0
    last_wall::Float64=wall()
    next_period::Float64=60.0
    mutex::ReentrantLock=ReentrantLock()
    stopped::Bool=false
    server::Any=nothing
    ticker::Any=nothing
    directory::String=""
    fixed_ready::Bool=false
    tick_intervals::Vector{Float64}=Float64[]
    http_times::Vector{Float64}=Float64[]
    replay::Vector{Any}=Any[]
    replay_actions::Vector{Any}=Any[]
    replay_mode::Bool=false
    initial_config::Dict{String,Any}=Dict{String,Any}()
    worker::Any=nothing
    release_pattern::Any=nothing
    timing_pattern::Any=nothing
    release_plans::Dict{String,Any}=Dict{String,Any}()
    cycle_conformance::CycleConformance=CycleConformance()
    replay_cycle_references::Vector{Any}=Any[]
    replay_releases::Dict{String,Any}=Dict{String,Any}()
    cached_cycle::Any=nothing
    best_cycle::Any=nothing
    reuse_pending::Bool=false
    reuse_count::Int=0
    last_reuse_at::Any=nothing
    scenario_signature::Any=nothing
    last_external_route::Any=nothing
    start_count::Int=0
    model_revision::Int=0
end

function Application(input)
    config,problem,mapping=prepare_config(input)
    sim=JS.load_config(config;advance_enabled=config["optimizer"]["simulation_start_mode"]!="after_optimization")
    app=Application(sim=sim,config=config,problem=problem,problem_id=problem===nothing ? nothing : problem_hash(problem),mapping=mapping,
        speed=JS.number(get(get(config,"clock",Dict()),"speed",1),"speed";positive=true),next_period=config["optimizer"]["period_sim_seconds"])
    app.directory=joinpath(ROOT,"results",Dates.format(now(),"yyyymmdd_HHMMSS")*"_"*string(uuid4()))
    mkpath(app.directory)
    app.initial_config=deepcopy(config)
    initialize_scenario_signature!(app)
    attach!(app)
    writejson(joinpath(app.directory,"config.json"),config)
    write_metadata(app)
    app
end
function write_metadata(app)
    sources=Dict(relpath(p,ROOT)=>bytes2hex(sha256(read(p))) for dir in (joinpath(ROOT,"src"),joinpath(ROOT,"bin"),joinpath(ROOT,"web"),joinpath(ROOT,"vendor","JobShopSim","src"),joinpath(SOLVER_ROOT,"src")) for p in readdir(dir;join=true) if endswith(p,".jl") || endswith(p,".html"))
    writejson(joinpath(app.directory,"metadata.json"),Dict("julia"=>string(VERSION),"cpu"=>Sys.CPU_NAME,"cpu_threads"=>Sys.CPU_THREADS,
        "seed"=>app.config["optimizer"]["seed"],"sources"=>sources,"dependencies"=>read(joinpath(ROOT,"Project.toml"),String),
        "manifest"=>isfile(joinpath(ROOT,"Manifest.toml")) ? read(joinpath(ROOT,"Manifest.toml"),String) : nothing,
        "solver_project"=>read(joinpath(SOLVER_ROOT,"Project.toml"),String),
        "solver_manifest"=>isfile(joinpath(SOLVER_ROOT,"Manifest.toml")) ? read(joinpath(SOLVER_ROOT,"Manifest.toml"),String) : nothing))
    nothing
end
function attach!(app)
    app.sim.transfer_selector = (sim,index)->priority_position(app,sim,index)
    app.sim.defer_zero_transfers=timing_enabled(app)
    app.sim.next_transfer_time=sim->next_timing_boundary(app,sim)
    app.sim.machine_dispatch_guard=(sim,job,id)->timing_machine_dispatch_allowed(app,sim,job,id)
    app.sim.after_settle=sim->check_timing_deadlines!(app,sim)
    app.sim.before_transfer_dispatch = sim->begin
        !app.replay_mode && app.reuse_pending && reusable_cycle(app) && reuse_cycle!(app)
        while !isempty(app.replay_actions) && first(app.replay_actions)["time"]<=sim.time
            action=popfirst!(app.replay_actions)
            if action["type"]=="transport_count_changed"
                JS.configure_transporters!(sim,action["count"])
            elseif action["type"]=="transfer_execution_changed"
                previous=dispatch_policy(app)
                app.config["optimizer"]["transfer_execution"]=action["mode"]
                clear_timing_pattern!(app);app.release_pattern=nothing
                record_dispatch_switch!(app,previous;reason="replay_transfer_execution_changed")
            else
                previous=dispatch_policy(app)
                app.config["control"]["mode"]=action["mode"]
                empty!(app.ranks);empty!(app.entries);app.order_id=nothing
                record_dispatch_switch!(app,previous;reason="replay_mode_changed")
            end
        end
        while !isempty(app.replay) && first(app.replay)["applied_at"]<=sim.time
            order=popfirst!(app.replay)
            req=Dict{String,Any}("request_id"=>"replay:"*order["request_id"])
            apply_order!(app,order["entries"],req;replayed=true)
        end
        settle_timed_loading!(app,sim)
    end
    app.sim.event_observer = (sim,e)->begin
        type=e["type"]; opts=app.config["optimizer"]
        if sim===app.sim && !app.replay_mode
            if type=="scenario_started"
                scenario_changed!(app,e["scenario"])
            elseif type=="job_added" && get(e,"source","")=="external"
                external_route_changed!(app,e["job"])
            end
        end
        type=="job_added" && sim===app.sim && plan_job_release!(app,e["job"])
        if type=="job_added" && app.replay_mode && timing_enabled(app) && app.timing_pattern!==nothing
            plan=get(app.timing_pattern["jobs"],e["job"],nothing)
            plan!==nothing && set_timed_durations!(sim.jobs[e["job"]],plan["durations"];travel_before=get(plan,"travel_before",nothing))
        end
        observe_timing!(app,sim,e)
        if type=="job_added" && sim===app.sim && app.replay_mode && haskey(app.replay_releases,e["job"])
            plan=app.replay_releases[e["job"]]
            defer_job_release!(app,e["job"],plan["at"];request_id=get(plan,"request_id",nothing))
        end
        if type=="job_released" && haskey(app.release_plans,e["job"])
            app.release_plans[e["job"]]["actual_at"]=sim.time
        end
        reason=type=="job_added" && opts["on_job_added"] ? "job_added" :
            type=="machine_failed" && opts["on_failure"] ? "failure" :
            type=="machine_repaired" && opts["on_repair"] ? "repair" : nothing
        reason !== nothing && trigger!(app,reason)
        observe_conformance!(app,sim,e)
    end
end
function trigger!(app,reason)
    app.replay_mode && return
    mode=app.config["control"]["mode"]
    reason=="periodic" && app.config["optimizer"]["recalculation_mode"]!="periodic" && return
    if reason=="job_added" && reusable_cycle(app)
        app.reuse_pending=true;return
    end
    reason in ("failure","repair","scenario_changed","route_changed","fault_mode_changed","transport_count_changed","settings_changed") && invalidate_cycle!(app)
    mode=="fixed_priority" && app.fixed_ready && reason=="job_added" && return
    push!(app.pending,reason)
end
function request!(app,reason="manual")
    app.problem===nothing && throw(ArgumentError("原W/R/N/V/L/U入力がないため順位は生成できません"))
    busy=app.active!==nothing
    push!(app.pending,reason)
    launch_pending!(app)
    busy ? pending_request_id(app) : app.active===nothing ? nothing : app.active["request_id"]
end
pending_request_id(app)=isempty(app.pending) ? nothing : "Q"*lpad(length(app.requests)+1,4,'0')
function cancel!(app;reason="cancelled",request_id=nothing)
    if reason in ("cancelled","shutdown","reset") && app.start_waiting
        app.start_waiting=false
        app.startup_error=reason=="cancelled" ? "計算を取り消し、自動開始を中止しました。JOB投入と時計の進行を保留しています。" : nothing
    end
    if app.active !== nothing && (request_id===nothing || request_id==app.active["request_id"])
        req=app.active
        stop_observer!(app,req)
        req["status"]=reason; req["finished_wall"]=wall(); req["total_wall_seconds"]=wall()-req["started_wall"]
        proc=get(req,"process",nothing)
        proc !== nothing && process_running(proc) && kill(proc)
        app.active=nothing
        JS.record!(app.sim,"optimizer_cancelled";request_id=req["request_id"],reason=reason)
    elseif request_id !== nothing
        throw(ArgumentError("実行中の要求IDではありません"))
    end
    empty!(app.pending)
    app.worker!==nothing && process_running(app.worker) && kill(app.worker)
    app.worker=nothing
end
public_request(req)=Dict(k=>deepcopy(v) for (k,v) in req if k ∉ ("process","task"))
function stop_observer!(app,req)
    directory=joinpath(get(req,"experiment_directory",app.directory),"requests",req["request_id"],"history")
    mkpath(directory);write(joinpath(directory,"STOP"),"stop")
end

# This is the effective selection method, not merely the requested GUI mode.
dispatch_policy(app)=timing_enabled(app) && app.timing_pattern!==nothing ? "cyclic_timing" : app.config["control"]["mode"] in ("fifo","compute_only") || isempty(app.ranks) ? "fifo" : app.config["control"]["mode"]
function record_dispatch_switch!(app,previous;reason,request_id=nothing)
    current=dispatch_policy(app)
    previous==current && return
    JS.record!(app.sim,"dispatch_policy_changed";from=previous,to=current,reason,
        request_id,order_id=app.order_id,configured_mode=app.config["control"]["mode"])
end

function problem_summary(problem,transport_count,mapping,opts)
    problem===nothing && return nothing
    p=SolverVerification.problem_from_dict(problem)
    Dict("routes"=>problem["R"],"stations"=>length(problem["W"]),
        "moves"=>length(p.moves),"terminals"=>count(p.terminal),
        "mapped_jobs"=>length(mapping),"transport_count"=>transport_count,
        "analytic_lower_bound"=>SolverVerification.analytic_lower_bound(p,transport_count),
        "period_upper"=>opts["upper"],"solver"=>opts["solver"],
        "solver_limit_wall_seconds"=>opts["solver_limit_wall_seconds"],"workers"=>opts["workers"],
        "stop_condition"=>get(opts,"stop_condition","time"),"gap_percent"=>get(opts,"gap_percent",1.0),
        "objective"=>"周期Tの最小化（整数秒）",
        "constraints"=>"処理時間L〜U、槽容量、搬送機の競合・回送・周期内帰還、終端の自動排出",
        "route_lengths"=>problem["N"],"station_ids"=>problem["W"],
        "routes_detail"=>[Dict("route"=>r,"stations"=>[problem["V"][i][r] for i in 1:problem["N"][r]+1],
            "lower"=>[problem["L"][i][r] for i in 1:problem["N"][r]],
            "upper"=>[problem["U"][i][r] for i in 1:problem["N"][r]]) for r in 1:problem["R"]])
end

function calculation_summary(app)
    active=app.active
    index=findlast(r->r["status"] ∉ ("starting","computing"),app.requests)
    last=index===nothing ? nothing : app.requests[index]
    response=last===nothing ? nothing : get(last,"result",nothing)
    result=response===nothing ? nothing : get(response,"result",nothing)
    summary=Dict{String,Any}("configured_solver"=>app.config["optimizer"]["solver"],
        "execution_policy"=>timing_enabled(app) ? (app.timing_pattern===nothing ? "timing_waiting" : "cyclic_timing") : app.config["control"]["mode"] in ("fifo","compute_only") || isempty(app.ranks) ? "fifo" : "priority",
        "available_solvers"=>[Dict("id"=>solver,"name"=>name,"solution_callback"=>supports_solution_callback(solver)) for (solver,name) in (("cp_sat","OR-Tools CP-SAT"),("highs","HiGHS MILP"))],
        "pattern_delivery"=>get(app.config["optimizer"],"pattern_delivery","final"),
        "available_execution_modes"=>["priority","cyclic_timing"],
        "configured_optimizer"=>deepcopy(app.config["optimizer"]),
        "callback_updates"=>active===nothing ? (isempty(app.requests) ? 0 : get(app.requests[end],"callback_updates",0)) : get(active,"callback_updates",0),
        "problem"=>active===nothing ? problem_summary(app.problem,length(app.sim.transporters),[id for id in keys(app.mapping) if id in app.sim.reserved_ids],app.config["optimizer"]) : active["problem_summary"],
        "active_solver"=>active===nothing ? nothing : active["optimizer"]["solver"],
        "phase"=>active===nothing ? "idle" : get(get(active,"progress",Dict()),"phase","initializing"),
        "elapsed_wall_seconds"=>active===nothing ? 0.0 : wall()-active["started_wall"],
        "request_id"=>active===nothing ? nothing : active["request_id"],
        "requested_at_simulation_time"=>active===nothing ? nothing : active["simulation_time"],
        "source_file"=>get(get(app.config,"input_info",Dict()),"source_file",nothing),
        "latest"=>nothing,"cycle"=>nothing,"live_result"=>nothing,
        "search_progress"=>active===nothing ? nothing : deepcopy(get(get(active,"progress",Dict()),"search_progress",nothing)))
    if last!==nothing
        solution=result===nothing ? nothing : get(result,"solution",nothing)
        T=solution===nothing ? nothing : solution["T"]
        bound=result===nothing ? nothing : get(result,"solver_bound",nothing)
        summary["latest"]=Dict("request_id"=>last["request_id"],"problem_id"=>last["problem_id"],"experiment_epoch"=>last["experiment_epoch"],"status"=>last["status"],
            "solver"=>last["optimizer"]["solver"],"period"=>T,"optimal"=>last["status"]=="OPTIMAL",
            "bound"=>bound,"gap_percent"=>T===nothing || bound===nothing ? nothing : max(0.0,100*(T-bound)/max(1,abs(T))),
            "application"=>get(last,"application",nothing),"error"=>get(last,"error",get(last,"rejection_reason",nothing)),
            "applied_period"=>get(last,"applied_period",T),"pattern_source_request_id"=>get(last,"pattern_source_request_id",last["request_id"]),
            "solve_seconds"=>result===nothing ? nothing : get(result,"solve_seconds",nothing),
            "termination_reason"=>result===nothing ? nothing : get(result,"termination_reason",nothing),
            "total_wall_seconds"=>get(last,"total_wall_seconds",nothing),
            "received"=>response!==nothing,
            "verified"=>result!==nothing && get(get(result,"verification",Dict()),"valid",false),
            "problem"=>last["problem_summary"])
    end
    valid_index=findlast(r->r["status"] in ("OPTIMAL","FEASIBLE") &&
        get(get(get(r,"result",Dict()),"result",Dict()),"solution",nothing)!==nothing,app.requests)
    if valid_index!==nothing
        r=app.requests[valid_index];res=r["result"]["result"]
        summary["cycle"]=Dict("request_id"=>r["request_id"],"problem_id"=>r["problem_id"],
            "experiment_epoch"=>r["experiment_epoch"],"solver"=>r["optimizer"]["solver"],
            "period"=>res["solution"]["T"],"optimal"=>r["status"]=="OPTIMAL","status"=>r["status"])
    end
    if active!==nothing && haskey(active,"incumbent") && active["model_revision"]==app.model_revision
        current=active["incumbent"]
        summary["intermediate"]=Dict("period"=>current["result"]["solution"]["T"],"index"=>current["index"],
            "application"=>current["application"],"simulation_time"=>current["simulation_time"],
            "applied_period"=>get(current,"applied_period",current["result"]["solution"]["T"]))
        raw=current["result"];search=summary["search_progress"]
        bound=get(raw,"solver_bound",nothing)
        if search!==nothing && get(search,"bound",nothing)!==nothing
            bound=bound===nothing ? search["bound"] : max(bound,search["bound"])
        end
        T=raw["solution"]["T"]
        summary["live_result"]=Dict("request_id"=>active["request_id"],"solver"=>active["optimizer"]["solver"],
            "period"=>T,"bound"=>bound,"gap_percent"=>bound===nothing ? nothing : max(0.0,100*(T-bound)/max(1,abs(T))),
            "optimal"=>false,"status"=>"FEASIBLE","intermediate"=>true,"received"=>true,"verified"=>true,
            "bound_current"=>search!==nothing,"application"=>current["application"],
            "solve_seconds"=>search===nothing ? get(raw,"solve_seconds",nothing) : get(search,"solver_seconds",nothing),
            "total_wall_seconds"=>wall()-active["started_wall"],"applied_period"=>get(current,"applied_period",T),
            "pattern"=>Dict(k=>deepcopy(raw["solution"][k]) for k in ("T","events","starts","hoists","is_terminal") if haskey(raw["solution"],k)))
        summary["cycle"]=Dict("request_id"=>active["request_id"],"problem_id"=>active["problem_id"],
            "experiment_epoch"=>active["experiment_epoch"],"solver"=>active["optimizer"]["solver"],
            "period"=>current["result"]["solution"]["T"],"optimal"=>false,"status"=>"FEASIBLE")
        if current["application"]=="retained_better_pattern" && reusable_cycle(app)
            cycle=app.cached_cycle
            summary["cycle"]=Dict("request_id"=>cycle["request_id"],"problem_id"=>app.problem_id,"experiment_epoch"=>app.epoch,
                "solver"=>cycle["solver"],"period"=>cycle["solution"]["T"],"optimal"=>cycle["status"]=="OPTIMAL","status"=>cycle["status"])
        end
    elseif reusable_cycle(app) && (summary["cycle"]===nothing || summary["cycle"]["request_id"]!=app.cached_cycle["request_id"])
        cycle=app.cached_cycle
        summary["cycle"]=Dict("request_id"=>cycle["request_id"],"problem_id"=>app.problem_id,"experiment_epoch"=>app.epoch,
            "solver"=>cycle["solver"],"period"=>cycle["solution"]["T"],"optimal"=>cycle["status"]=="OPTIMAL","status"=>cycle["status"])
    end
    summary
end

function launch_pending!(app)
    app.replay_mode && return
    app.reuse_pending && reusable_cycle(app) && reuse_cycle!(app)
    app.active !== nothing && return
    isempty(app.pending) && return
    if app.problem===nothing
        empty!(app.pending); return
    end
    id="Q"*lpad(length(app.requests)+1,4,'0')
    req=Dict{String,Any}("request_id"=>id,"experiment_epoch"=>app.epoch,"experiment_directory"=>app.directory,"problem_id"=>app.problem_id,
        "transport_count"=>length(app.sim.transporters),"mapping"=>registered_mapping(app),"problem"=>deepcopy(app.problem),
        "optimizer"=>deepcopy(app.config["optimizer"]),"reasons"=>sort(collect(app.pending)),"simulation_time"=>app.sim.time,
        "started_wall"=>wall(),"status"=>"starting","paused_at_request"=>!app.running,"speed_at_request"=>app.speed,
        "cycle_key"=>cycle_key(app),"model_revision"=>app.model_revision,"start_count"=>app.start_count)
    req["problem_summary"]=problem_summary(req["problem"],req["transport_count"],req["mapping"],req["optimizer"])
    empty!(app.pending);push!(app.requests,req);app.active=req
    JS.record!(app.sim,"optimizer_started";request_id=id,reasons=req["reasons"])
    directory=joinpath(app.directory,"requests",id);mkpath(directory)
    # File IO, process startup, waiting, JSON parsing and numeric solution validation are outside the simulation lock.
    req["task"]=@async begin
        result=nothing; failure=nothing
        try
            writejson(joinpath(directory,"request.json"),public_request(req))
            experiment_directory=dirname(dirname(directory))
            cmd=`$(Base.julia_cmd()) --startup-file=no --project=$SOLVER_ROOT $(joinpath(ROOT,"bin","solver_worker.jl")) --service $experiment_directory $id`
            cmd=Cmd(cmd;windows_hide=true)
            begin
                current,proc=lock(app.mutex) do;(app.active===req && !app.stopped,app.worker);end
                if !current
                    writejson(joinpath(directory,"completed.json"),public_request(req))
                    return
                end
                reused=proc!==nothing && process_running(proc)
                if !reused
                    proc=open(joinpath(experiment_directory,"worker.log"),"a") do io
                        run(pipeline(cmd,stdout=io,stderr=io);wait=false)
                    end
                end
                lock(app.mutex) do
                    req["process"]=proc
                    req["warm_worker_reused"]=reused
                    if app.active!==req
                        process_running(proc) && kill(proc)
                    else
                        app.worker=proc
                        req["status"]="computing"
                    end
                end
                while process_running(proc) && !isfile(joinpath(directory,"response.json"))
                    sleep(0.025)
                    receive_pending_incumbents!(app,req,directory)
                    progress_path=joinpath(directory,"progress.json")
                    if isfile(progress_path)
                        progress=try; readjson(progress_path); catch; nothing; end
                        progress!==nothing && lock(app.mutex) do
                            app.active===req && (req["progress"]=progress)
                        end
                    end
                    expired=request_deadline_expired(req["optimizer"],wall()-req["started_wall"])
                    invalid=lock(app.mutex) do; app.active!==req || app.stopped; end
                    if expired || invalid
                        stop_observer!(app,req)
                        kill(proc);expired && (failure="deadline_exceeded");break
                    end
                end
                !process_running(proc) && wait(proc)
                if failure===nothing
                    receive_pending_incumbents!(app,req,directory)
                    isfile(joinpath(directory,"response.json")) || error("ワーカープロセス異常終了。worker.logを確認してください")
                    result=readjson(joinpath(directory,"response.json"))
                    if result["status"] in ("OPTIMAL","FEASIBLE")
                        original=result["result"]
                        problem=SolverVerification.problem_from_dict(req["problem"])
                        verification=SolverVerification.verify_result(problem,original)
                        verification["valid"] || error("原解の再検証不合格")
                        validate_entries(result["entries"],req["mapping"])
                        result["entries"]==extract_order(original["solution"],req["mapping"]) || error("原解と順位が不一致")
                    end
                end
            end
        catch err
            failure=sprint(showerror,err)
            failed_proc=get(req,"process",nothing)
            if failed_proc!==nothing && process_running(failed_proc)
                stop_observer!(app,req);kill(failed_proc)
            end
        end
        lock(app.mutex) do
            app.active===req || return
            sync_clock!(app)
            app.active===req || return
            req["finished_wall"]=wall();req["total_wall_seconds"]=wall()-req["started_wall"]
            req["received_simulation_time"]=app.sim.time
            req["result"]=result
            result!==nothing && haskey(result,"error") && (req["error"]=result["error"])
            req["status"]=failure===nothing ? result["status"] : failure=="deadline_exceeded" ? "DEADLINE_EXCEEDED" : "ERROR"
            if failure!==nothing
                req["error"]=failure
            elseif result["status"] in ("OPTIMAL","FEASIBLE")
                try
                    # Additions made while solving belong to the same periodic
                    # model. Expand the received solution against today's IDs.
                    apply_pattern_result!(app,result,req;preserve_anchor=get(req,"callback_updates",0)>0)
                catch err
                    req["application"]="rejected";req["rejection_reason"]=sprint(showerror,err)
                    trigger!(app,"stale_result")
                end
            end
            JS.record!(app.sim,"optimizer_received";request_id=id,status=req["status"],application=get(req,"application",nothing))
            app.active=nothing
            finish_simulation_start!(app,req)
        end
        writejson(joinpath(directory,"completed.json"),public_request(req))
    end
end
function apply_order!(app,entries,req;replayed=false,previous=dispatch_policy(app))
    app.order_id="O"*lpad(length(app.orders)+1,4,'0')
    frozen=Any[];sizehint!(frozen,length(entries))
    shared=Dict{String,TransferEntry}()
    for entry in entries
        token=get!(app.transfer_tokens,entry["transfer_id"],entry["transfer_id"])
        prior=get(app.shared_entries,token,nothing)
        row=prior!==nothing && prior.rank==entry["rank"] && prior.job_id==entry["job_id"] && prior.source_operation==entry["source_operation"] ? prior :
            TransferEntry(entry["rank"],token,entry["job_id"],entry["source_operation"])
        push!(frozen,row);shared[token]=row
    end
    app.shared_entries=shared;app.entries=frozen
    app.ranks=Dict(e["transfer_id"]=>e["rank"] for e in entries)
    order=Dict("order_id"=>app.order_id,"request_id"=>req["request_id"],"experiment_epoch"=>app.epoch,
        "problem_id"=>app.problem_id,"entries"=>copy(frozen),"applied_at"=>app.sim.time,"replayed"=>replayed)
    push!(app.orders,order);req["application"]="applied";req["applied_simulation_time"]=app.sim.time
    req["receive_to_apply_wall_seconds"]=max(0.0,wall()-get(req,"finished_wall",wall()))
    app.fixed_ready=true
    app.config["control"]["mode"]=="fixed_priority" && delete!(app.pending,"job_added")
    JS.record!(app.sim,"order_applied";order_id=app.order_id,request_id=req["request_id"])
    record_dispatch_switch!(app,previous;reason=replayed ? "replay_order_applied" : "order_applied",request_id=req["request_id"])
    # In-flight jobs and destination reservations are never changed by order replacement.
end

function advance_app!(app,target)
    app.sim.advance_enabled || return
    while app.sim.time < target
        periodic=app.config["optimizer"]["recalculation_mode"]=="periodic"
        boundary=periodic ? min(target,app.next_period) : target
        !isempty(app.replay) && (boundary=min(boundary,first(app.replay)["applied_at"]))
        !isempty(app.replay_actions) && (boundary=min(boundary,first(app.replay_actions)["time"]))
        JS.advance!(app.sim,boundary;stop_when_complete=true)
        timing_failed(app) && break
        if periodic && app.sim.time>=app.next_period
            trigger!(app,"periodic");app.next_period+=app.config["optimizer"]["period_sim_seconds"]
        end
        JS.advance!(app.sim,app.sim.time)
        JS.all_jobs_completed(app.sim) && break
    end
    if JS.all_jobs_completed(app.sim)
        empty!(app.pending)
    end
end
function sync_clock!(app;max_wall_step=0.1)
    current=wall()
    if app.running
        # Keep delayed wall time pending, but release the lock between slices so
        # callbacks and HTTP requests are not trapped in an unbounded catch-up.
        elapsed=min(max(0.0,current-app.last_wall),max_wall_step)
        advance_app!(app,app.sim.time+elapsed*app.speed)
        app.last_wall=min(current,app.last_wall+elapsed)
        if JS.all_jobs_completed(app.sim)
            app.running=false;empty!(app.pending)
            app.last_wall=current
            # Keep the current solve alive so its cyclic result can still be inspected.
        end
    else
        app.last_wall=current
    end
end

function compact_request(req)
    data=Dict(k=>deepcopy(v) for (k,v) in req if k ∉ ("process","task","mapping","problem","result","incumbent"))
    if haskey(req,"incumbent")
        current=req["incumbent"];solution=current["result"]["solution"]
        data["incumbent"]=Dict("index"=>current["index"],"simulation_time"=>current["simulation_time"],"application"=>current["application"],
            "result"=>Dict("solution"=>Dict(k=>deepcopy(v) for (k,v) in solution if k in ("T","events","starts","hoists","is_terminal"))))
    end
    response=get(req,"result",nothing)
    if response!==nothing
        result=get(response,"result",nothing)
        brief=Dict{String,Any}("error"=>get(response,"error",nothing))
        if result!==nothing
            solution=get(result,"solution",nothing)
            brief["result"]=Dict("solution"=>solution===nothing ? nothing : Dict(k=>deepcopy(v) for (k,v) in solution if k in ("T","events","starts","hoists","is_terminal")))
        end
        data["result"]=brief
    end
    data
end
function optimizer_status(app;compact=false)
    public=compact ? compact_request : public_request
    Dict("active"=>app.active===nothing ? nothing : public(app.active),"pending_reasons"=>sort(collect(app.pending)),"pending_request_id"=>pending_request_id(app),
        "next_period"=>app.next_period,"order_id"=>app.order_id,"requests"=>[public(r) for r in app.requests],
        "calculation"=>calculation_summary(app),"reuse"=>reuse_summary(app),
        "model_note"=>"周期モデルは仕掛品残り時間・故障を直接最適化しません。周期Tは実績完了時刻ではありません。")
end
