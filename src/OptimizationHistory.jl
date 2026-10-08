# Read only per-request artifacts. No optimizer or simulator locks are held
# while reading SVGs or serializing the convergence data.
const OPTIMIZATION_PLOT_MUTEX=ReentrantLock()
function optimization_history_request(app,params)
    lock(app.mutex) do
        id=get(params,"request",app.active===nothing ? (isempty(app.requests) ? "" : last(app.requests)["request_id"]) : app.active["request_id"])
        index=findfirst(r->r["request_id"]==id,app.requests)
        index===nothing && return nothing
        req=app.requests[index]
        Dict("request_id"=>id,"status"=>req["status"],"directory"=>joinpath(app.directory,"requests",id,"history"),
            "error"=>get(req,"error",nothing),
            "stop_condition"=>get(req["optimizer"],"stop_condition","time"),"gap_percent"=>get(req["optimizer"],"gap_percent",1.0),
            "solver_limit_wall_seconds"=>req["optimizer"]["solver_limit_wall_seconds"])
    end
end
function optimization_history_response(app,req,path)
    params=HTTP.URIs.queryparams(HTTP.URI(req.target))
    current=optimization_history_request(app,params)
    if current===nothing
        (path=="/api/optimizer/frame" || haskey(params,"request")) && return response(404,Dict("error"=>"計算要求がありません"))
        return response(200,Dict("request_id"=>nothing,"status"=>"idle","entries"=>Any[],"final"=>nothing))
    end
    directory=current["directory"];manifest=joinpath(directory,"history.json")
    state=isfile(manifest) ? readjson(manifest) : Dict{String,Any}("entries"=>Any[],"final"=>nothing,"error"=>nothing)
    progress_file=joinpath(directory,"native-progress.json")
    if isfile(progress_file)
        progress=try;readjson(progress_file);catch;nothing;end
        progress!==nothing && (state["progress"]=progress)
    end
    if path=="/api/optimizer/history"
        return response(200,merge(state,current))
    end
    index=tryparse(Int,get(params,"index","0"))
    index!==nothing && 1<=index<=length(state["entries"]) || return response(404,Dict("error"=>"改善解がありません"))
    entry=state["entries"][index];prefix=entry["prefix"]
    occursin(r"^incumbent_[0-9]{6}$",prefix) || return response(400,Dict("error"=>"改善解の形式が不正です"))
    trajectory=joinpath(directory,prefix*"_trajectory.svg");gantt=joinpath(directory,prefix*".svg")
    if !(isfile(trajectory) && isfile(gantt))
        lock(OPTIMIZATION_PLOT_MUTEX) do
            if !(isfile(trajectory) && isfile(gantt))
                data_path=joinpath(directory,prefix*".json")
                isfile(data_path) || throw(ArgumentError("改善解のデータを作成中です"))
                input_path=joinpath(directory,"input.json")
                input=isfile(input_path) ? readjson(input_path) : readjson(joinpath(dirname(directory),"request.json"))["problem"]
                problem=SolverVerification.problem_from_dict(input)
                SolverVerification.export_plots(problem,readjson(data_path),joinpath(directory,prefix))
            end
        end
    end
    response(200,merge(entry,Dict("request_id"=>current["request_id"],"trajectory"=>read(trajectory,String),"gantt"=>read(gantt,String))))
end
