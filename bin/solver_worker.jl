# No Python, PythonCall, PyCall, or Python process is used.
using JSON
const ROOT=normpath(joinpath(@__DIR__,".."))
include(joinpath(ROOT,"vendor","HoistScheduling","src","HoistScheduling.jl"))
include(joinpath(ROOT,"src","TransferOrderExtractor.jl"))
include(joinpath(ROOT,"src","OptimizationTermination.jl"))
const HINTS=Dict{Tuple{String,Int,Int},String}()
function compute(request_path,response_path)
request=JSON.parsefile(request_path)
started=Float64(time_ns())/1e9
history_directory=joinpath(dirname(response_path),"history")
search_attempt=1;previous_gap=nothing;latest_search_progress=nothing
function progress(phase;search_progress=nothing)
    search_progress!==nothing && (latest_search_progress=search_progress)
    path=joinpath(dirname(response_path),"progress.json")
    data=Dict{String,Any}("phase"=>phase,"worker_elapsed_wall_seconds"=>Float64(time_ns())/1e9-started,"history_directory"=>history_directory,
        "search_attempt"=>search_attempt,"previous_gap_percent"=>previous_gap)
    latest_search_progress!==nothing && (data["search_progress"]=latest_search_progress)
    HoistScheduling.write_json(path,data)
end
response=try
    opts=request["optimizer"]
    problem=HoistScheduling.problem_from_dict(request["problem"])
    solver=get(opts,"solver","cp_sat")
    delivery=get(opts,"pattern_delivery","final")
    delivery=="incremental" && !(solver in ("cp_sat","highs")) && error("このソルバーでは対応していません")
    update_index=0;best_published=Inf
    function publish_incumbent(result,elapsed)
        delivery=="incremental" || return
        T=result["solution"]["T"];T<best_published || return
        result["verification"]["valid"] || error("未検証の改善解です")
        best_published=T;update_index+=1
        payload=Dict("request_id"=>request["request_id"],"experiment_epoch"=>request["experiment_epoch"],
            "problem_id"=>request["problem_id"],"transport_count"=>request["transport_count"],
            "model_revision"=>request["model_revision"],"index"=>update_index,"solver_seconds"=>elapsed,
            "result"=>merge(result,Dict("solver"=>solver,"status"=>"FEASIBLE","solve_seconds"=>elapsed)))
        folder=joinpath(history_directory,"delivery");mkpath(folder)
        HoistScheduling.write_json(joinpath(folder,"update_$(lpad(update_index,6,'0')).json"),payload)
        HoistScheduling.write_json(joinpath(folder,"index.json"),Dict("count"=>update_index))
    end
    key=(String(request["problem_id"]),Int(request["transport_count"]),Int(opts["upper"]))
    stop_condition=get(opts,"stop_condition","time")
    limits=termination_settings(opts)
    seconds=limits.seconds
    mkpath(history_directory)
    # The diagram endpoint needs the model input for either solver.
    HoistScheduling.write_json(joinpath(history_directory,"input.json"),request["problem"])
    history=nothing;solver_offset=0.0
    result=solve_until_gap(opts;on_retry=(r,attempt)->begin
        isfile(joinpath(history_directory,"STOP")) && error("探索は取消されました")
        previous_gap=solution_gap_percent(r);solver_offset=r["solve_seconds"]
        solver=="cp_sat" && HoistScheduling.write_json(joinpath(history_directory,"final.json"),r)
        history.result=nothing;history.status="RUNNING"
        HoistScheduling.export_history!(history;animation=false)
        progress("gap_continuation")
    end) do attempt,relative_gap
        search_attempt=attempt
        isfile(joinpath(history_directory,"STOP")) && error("探索は取消されました")
        if solver=="cp_sat"
            archive=attempt>1 ? HoistScheduling.archive_native_attempt!(history_directory,attempt-1) : nothing
            input_path=joinpath(history_directory,"input.json")
            open(input_path,"w") do io;JSON.print(io,request["problem"]);end
            hint=archive===nothing ? get(HINTS,key,nothing) : previous_gap===nothing ? nothing : joinpath(archive,"final.json")
            history=HoistScheduling.start_history(input_path;directory=history_directory,seconds,relative_gap,
                hoists=request["transport_count"],workers=opts["workers"],seed=opts["seed"]+attempt-1,upper=opts["upper"],
                hint,on_phase=progress,on_incumbent=publish_incumbent,resume=history,elapsed_offset=solver_offset,
                render_improvements=false,on_progress=p->progress("solving";search_progress=p))
            HoistScheduling.wait_history(history)
        elseif solver=="highs"
            history===nothing && (history=HoistScheduling.HistoryRun(history_directory,nothing,nothing,"RUNNING",nothing,Dict{String,Any}[],nothing,false))
            history.render_improvements=false
            HoistScheduling.export_history!(history;animation=false)
            current=HoistScheduling.solve_highs(problem;seconds,relative_gap,hoists=request["transport_count"],
                workers=opts["workers"],seed=opts["seed"]+attempt-1,upper=opts["upper"],on_phase=progress,
                on_incumbent=(r,t)->begin
                    publish_incumbent(r,solver_offset+t)
                    if isempty(history.entries) || r["solution"]["T"]<last(history.entries)["T"]
                        HoistScheduling.record_improvement!(history,problem,r,solver_offset+t;source="highs_solution_observer")
                    end
                end)
            current["solve_seconds"]+=solver_offset
            if current["solution"]!==nothing && (isempty(history.entries) || current["solution"]["T"]<last(history.entries)["T"])
                publish_incumbent(current,current["solve_seconds"])
                HoistScheduling.record_improvement!(history,problem,current,current["solve_seconds"];source="final_response")
            end
            history.result=current;history.status=current["status"]
            HoistScheduling.export_history!(history)
            current
        else
            error("Unknown solver: $solver")
        end
    end
    history.result=result;history.status=result["status"]
    HoistScheduling.export_history!(history)
    result["solver"]=solver
    result["stop_condition"]=stop_condition
    result["gap_target_percent"]=limits.gap_target_percent
    actual_gap=solution_gap_percent(result)
    result["gap_percent"]=actual_gap
    result["termination_reason"]=optimization_termination_reason(result,opts,actual_gap)
    progress("extracting_order")
    entries=result["solution"]===nothing ? Any[] : extract_order(result["solution"],request["mapping"])
    result["solution"]!==nothing && validate_entries(entries,request["mapping"])
    if result["solution"]!==nothing && solver=="cp_sat"
        hint_path=joinpath(dirname(response_path),"hint.json")
        open(hint_path,"w") do io;JSON.print(io,result);end
        HINTS[key]=hint_path
    end
    Dict("status"=>result["status"],"result"=>result,"entries"=>entries,"worker_wall_seconds"=>Float64(time_ns())/1e9-started)
catch err
    Dict("status"=>"ERROR","error"=>sprint(showerror,err),"entries"=>Any[])
end
open(response_path*".tmp","w") do io;JSON.print(io,response,2);end
mv(response_path*".tmp",response_path;force=true)
end
if ARGS[1]=="--service"
    requests=joinpath(ARGS[2],"requests")
    seen=Set{String}()
    while true
        for dir in sort(readdir(requests;join=true))
            basename(dir)<ARGS[3] && continue # Never restart cancelled requests from an older worker.
            input=joinpath(dir,"request.json")
            isfile(input) && !(input in seen) || continue
            push!(seen,input)
            compute(input,joinpath(dir,"response.json"))
        end
        sleep(0.02)
    end
else
    compute(ARGS[1],ARGS[2])
end
