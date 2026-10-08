# 一度のCP-SAT探索で発生した改善解を、届いた順に保存します。
# Notebookはこの処理を非同期で開始するので、計算中も操作できます。

mutable struct HistoryRun
    directory::String
    task::Union{Nothing,Task}
    process::Any
    status::String
    error::Union{Nothing,String}
    entries::Vector{Dict{String,Any}}
    result::Any
    stop_requested::Bool
    render_improvements::Bool
end
HistoryRun(directory,task,process,status,error,entries,result,stop_requested)=
    HistoryRun(directory,task,process,status,error,entries,result,stop_requested,true)
include("native_progress.jl")

function write_json(path,object)
    # Notebookの読み取りと競合しないよう、一時ファイルを経由します。
    temporary=path*".tmp"
    open(temporary,"w") do io
        JSON.print(io,object,2)
    end
    # Windows may briefly deny replacement while the GUI reads the file.
    # Retry the atomic rename; mv(force=true) can fall back to deleting or
    # copying the destination and turn a harmless read into a solver error.
    for attempt in 1:200
        try
            Base.Filesystem.rename(temporary,path)
            return path
        catch err
            retry=Sys.iswindows() && err isa Base.IOError && err.code in (Base.UV_EBUSY,Base.UV_EACCES,Base.UV_EPERM)
            retry && attempt<200 || rethrow()
            sleep(0.01)
        end
    end
end

function history_status(run::HistoryRun)
    return (status=run.status,updates=length(run.entries),
            best=isempty(run.entries) ? nothing : last(run.entries)["T"],
            directory=run.directory,error=run.error)
end

"""探索を止めます。保存済みの改善解と図は残り、最後の応答も受け取ります。"""
function stop_history!(run::HistoryRun)
    run.status in ("PREPARING","RUNNING") || return run
    run.stop_requested=true
    write(joinpath(run.directory,"STOP"),"stop")
    return run
end

function wait_history(run::HistoryRun)
    wait(run.task)
    isnothing(run.error) || error(run.error)
    return run.result
end

function encode_proto(object)
    io=IOBuffer()
    ORTools.PB.encode(ORTools.PB.ProtoEncoder(io),ORTools.to_proto_struct(object))
    return take!(io)
end
decode_response(path)=ORTools.PB.decode(ORTools.PB.ProtoDecoder(IOBuffer(read(path))),ORTools.CpSolverResponse)

function archive_native_attempt!(directory,attempt)
    isfile(joinpath(directory,"STOP")) && error("探索は取消されました")
    archive=joinpath(directory,@sprintf("search_%06d",attempt));mkpath(archive)
    for name in readdir(directory)
        (endswith(name,".bin") || name in ("config.json","native_process.json","final.json","solver.log")) || continue
        isfile(joinpath(directory,name)) || continue
        mv(joinpath(directory,name),joinpath(archive,name);force=true)
    end
    archive
end

"""
    start_history(input; seconds=120, hoists=1, upper=10000, hint=nothing)

バックグラウンドで探索を開始し、操作用のHistoryRunを直ちに返します。
出力は実行ごとの新しいフォルダーです。以前の実験を上書きしません。
"""
function start_history(input::AbstractString;seconds=120.0,hoists=1,workers=8,seed=1,
                       upper=10000,target=nothing,hint=nothing,
                       relative_gap=0.0,directory=nothing,on_phase=(_->nothing),on_incumbent=(_,_)->nothing,
                       output_root=joinpath(@__DIR__,"..","results","history"),resume=nothing,elapsed_offset=0.0,
                       render_improvements=true,on_progress=(_->nothing))
    seconds===nothing || seconds>0 || error("制限時間は正にしてください")
    workers>=1 || error("workersは1以上にしてください")
    problem=read_problem(abspath(input))
    executable=joinpath(@__DIR__,"..","vendor","history_bridge","build",
                        Sys.iswindows() ? "hoist_observer.exe" : "hoist_observer")
    isfile(executable) || error("初回は julia --project=. build_history_bridge.jl を実行してください")
    directory=directory===nothing ? abspath(joinpath(output_root,Dates.format(now(),"yyyymmdd_HHMMSS")*"_"*string(uuid4())[1:8])) : abspath(directory)
    mkpath(directory)
    run=resume===nothing ? HistoryRun(directory,nothing,nothing,"PREPARING",nothing,Dict{String,Any}[],nothing,false) : resume
    run.directory==directory || error("継続探索の履歴フォルダーが不一致です")
    run.render_improvements=render_improvements
    run.status="PREPARING";run.error=nothing;run.result=nothing
    config=Dict("input"=>abspath(input),"seconds"=>seconds,"hoists"=>hoists,"workers"=>workers,
                "seed"=>seed,"upper"=>upper,"target"=>target,"hint"=>hint,
                "relative_gap"=>relative_gap,"created_at"=>string(now()),"history_source"=>"CP-SAT NewFeasibleSolutionObserver")
    write_json(joinpath(directory,"config.json"),config)
    write_json(joinpath(directory,"input.json"),problem.raw)
    resume===nothing && write(joinpath(directory,"improvements.csv"),"index,solver_seconds,T,bound,improvement,gap_percent\n")
    run.task=@async try
        yield() # Notebookへ一旦制御を返します。
        on_phase("building_model")
        model,extras,vars,lower=build_model(problem;hoists,upper,target)
        !isnothing(hint) && !isempty(hint) && apply_hint!(problem,vars,abspath(hint))
        cp,ids=compile_cp(model,extras)
        parameters=ORTools.SatParameters()
        seconds!==nothing && (parameters.max_time_in_seconds=Float64(seconds))
        parameters.relative_gap_limit=Float64(relative_gap)
        parameters.absolute_gap_limit=0.0
        parameters.num_search_workers=Int32(workers)
        parameters.random_seed=Int32(seed)
        parameters.log_search_progress=true
        write(joinpath(directory,"model.bin"),encode_proto(cp))
        write(joinpath(directory,"parameters.bin"),encode_proto(parameters))
        options=(;hoists,seconds,workers,seed,upper,target,lower)
        # JLLの実行環境からDLL検索パスを継承します。グローバルPATHは変更しません。
        jll_command=ORTools_jll.sat_runner()
        environment=isnothing(jll_command.env) ? copy(ENV) : Dict(split(e,'=';limit=2)[1]=>split(e,'=';limit=2)[2] for e in jll_command.env)
        runtime=abspath(joinpath(@__DIR__,"..","..","..","runtime","windows_runtime"))
        separator=Sys.iswindows() ? ';' : ':'
        environment["PATH"]=join([runtime,get(environment,"PATH",get(ENV,"PATH",""))],separator)
        command=setenv(Cmd(Cmd([abspath(executable)]);dir=directory,windows_hide=true),environment)
        open(joinpath(directory,"solver.log"),"w") do logfile
            run.process=Base.run(pipeline(command,stdout=logfile,stderr=logfile);wait=false)
            write_json(joinpath(directory,"native_process.json"),Dict("pid"=>getpid(run.process)))
            run.status="RUNNING"
            on_phase("solving")
            last_native_index=0
            progress_reader=NativeProgressReader(joinpath(directory,"solver.log"))
            native_started=Float64(time_ns())/1e9
            function publish_progress!()
                state=read_native_progress!(progress_reader;elapsed=Float64(time_ns())/1e9-native_started)
                state["solver_seconds"]+=elapsed_offset
                write_json(joinpath(directory,"native-progress.json"),state)
                on_progress(state)
            end
            function collect_new!()
                files=sort(filter(n->occursin(r"^incumbent_\d+\.bin$",n),readdir(directory)))
                for name in files
                    index=parse(Int,match(r"\d+",name).match)
                    index<=last_native_index && continue
                    response=decode_response(joinpath(directory,name))
                    result=result_from_response(problem,vars,ids,response;options...)
                    last_native_index=index
                    if isempty(run.entries) || result["solution"]["T"]<last(run.entries)["T"]
                        on_incumbent(result,elapsed_offset+response.wall_time)
                        record_improvement!(run,problem,result,elapsed_offset+response.wall_time)
                    end
                    yield() # 大量の更新が一度に届いても、Notebookの操作へ制御を返します。
                end
            end
            while process_running(run.process)
                collect_new!()
                publish_progress!()
                sleep(0.2)
            end
            wait(run.process)
            collect_new!()
            publish_progress!()
            success(run.process) || error("履歴取得プロセスが終了コード$(run.process.exitcode)で失敗しました。solver.logを参照してください")
        end
        response=decode_response(joinpath(directory,"final.bin"))
        on_phase("validating")
        result=result_from_response(problem,vars,ids,response;options...,output=joinpath(directory,"final.json"))
        # 初期処理だけで最適性が確定した場合にも、最終解を失わないようにします。
        if !isnothing(result["solution"]) && (isempty(run.entries) || result["solution"]["T"]<last(run.entries)["T"])
            on_incumbent(result,elapsed_offset+response.wall_time)
            record_improvement!(run,problem,result,elapsed_offset+response.wall_time;source="final_response")
        end
        result["solve_seconds"]+=elapsed_offset
        run.result=result
        run.status=run.stop_requested ? "STOPPED" : result["status"]
        export_history!(run)
    catch exception
        run.error=sprint(showerror,exception,catch_backtrace())
        run.status="ERROR"
        write(joinpath(directory,"error.log"),run.error)
        # エラー時も子プロセスを残しません。
        if !isnothing(run.process) && process_running(run.process)
            write(joinpath(directory,"STOP"),"stop")
            kill(run.process)
            wait(run.process)
        end
        export_history!(run)
    end
    return run
end

function record_improvement!(run,p,result,elapsed;source="solution_observer")
    T=result["solution"]["T"]
    previous=isempty(run.entries) ? nothing : last(run.entries)["T"]
    !isnothing(previous) && T>=previous && error("改善履歴の目的値が減少していません")
    index=length(run.entries)+1
    prefix=@sprintf("incumbent_%06d",index)
    write_json(joinpath(run.directory,prefix*".json"),result)
    run.render_improvements && export_plots(p,result,joinpath(run.directory,prefix))
    bound=max(result["analytic_lower_bound"],result["solver_bound"])
    entry=Dict{String,Any}("index"=>index,"solver_seconds"=>elapsed,"T"=>T,"bound"=>bound,
        "improvement"=>isnothing(previous) ? nothing : previous-T,"gap_percent"=>100*(T-bound)/max(1,abs(T)),
        "prefix"=>prefix,"source"=>source,"recorded_at"=>string(now()))
    push!(run.entries,entry)
    open(joinpath(run.directory,"improvements.csv"),"a") do io
        println(io,join((index,elapsed,T,bound,isnothing(previous) ? "" : previous-T,entry["gap_percent"]),","))
    end
    open(joinpath(run.directory,"improvements.jsonl"),"a") do io
        JSON.print(io,entry); println(io)
    end
    export_history!(run;animation=false)
    @info "最良解更新" index solver_seconds=round(elapsed;digits=3) T bound
end

function export_history!(run;animation=true)
    final=isnothing(run.result) ? nothing : Dict("status"=>run.result["status"],
        "T"=>run.result["solution"]===nothing ? nothing : run.result["solution"]["T"],
        "gap_percent"=>run.result["solution"]===nothing || run.result["solver_bound"]===nothing ? nothing :
            max(0.0,100*(run.result["solution"]["T"]-run.result["solver_bound"])/max(1,abs(run.result["solution"]["T"]))),
        "solver_seconds"=>run.result["solve_seconds"],"bound"=>run.result["solver_bound"]===nothing ? run.result["analytic_lower_bound"] : max(run.result["analytic_lower_bound"],run.result["solver_bound"]))
    write_json(joinpath(run.directory,"history.json"),Dict("status"=>run.status,"error"=>run.error,"entries"=>run.entries,"final"=>final))
    # 全フレームのHTMLは終了時にまとめて書きます。計算中のPluto表示はhistory.jsonを読みます。
    animation && run.render_improvements && write(joinpath(run.directory,"animation.html"),history_html(run.directory))
end

include("history_viewer.jl")
