using JobShopSimProposedMethod, JobShopSim, HTTP, JSON3, Pkg, Libdl
const PM = JobShopSimProposedMethod
const ROOT = PM.ROOT
inside(path)=startswith(lowercase(replace(abspath(path),'\\'=>'/')),lowercase(replace(ROOT,'\\'=>'/'))*"/")
@assert inside(Sys.BINDIR) "Julia本体がフォルダー外です"
@assert length(DEPOT_PATH)==1 && inside(only(DEPOT_PATH)) "外部depotを参照しています"
sources=Dict{String,String}()
for project in (ROOT,PM.SOLVER_ROOT)
    Pkg.activate(project)
    for info in values(Pkg.dependencies())
        info.source===nothing && continue
        @assert inside(info.source) "フォルダー外の依存: $(info.name): $(info.source)"
        sources[info.name]=info.source
    end
end
Pkg.activate(ROOT)
config=PM.readjson(joinpath(ROOT,"examples","default.json"))
config["optimizer"]["solver_limit_wall_seconds"]=1
config["optimizer"]["request_limit_wall_seconds"]=240
config["optimizer"]["warmup"]=false
app=PM.start_server(config;port=0)
base="http://127.0.0.1:$(HTTP.port(app.server))"
api(path)=JSON3.read(String(HTTP.get(base*path).body),Dict{String,Any})
post(path,data)=HTTP.post(base*path,["Content-Type"=>"application/json"],JSON3.write(data);status_exception=false)
try
    @assert HTTP.get(base*"/").status==200
    @assert post("/api/control",Dict("action"=>"start")).status==200
    before=api("/api/state")["time"]
    sleep(0.5)
    @assert api("/api/state")["time"]>before
    started=PM.wall()
    while !any(r->get(r,"application",nothing)=="applied",app.requests)
        PM.wall()-started>240 && error("同梱ソルバーの適用待ちがタイムアウトしました")
        sleep(0.05)
    end
    request=first(filter(r->get(r,"application",nothing)=="applied",app.requests))
    @assert request["status"] in ("OPTIMAL","FEASIBLE")
    @assert request["result"]["result"]["verification"]["valid"]
    @assert post("/api/control",Dict("action"=>"pause")).status==200
    @assert post("/api/optimizer/cancel",Dict()).status==200
    app.config["control"]["mode"]="fifo"
    @assert post("/api/control",Dict("action"=>"step","seconds"=>100000)).status==200
    @assert api("/api/state")["completed"]
    report=Dict("passed"=>true,"root"=>ROOT,"julia"=>Sys.BINDIR,"depot"=>DEPOT_PATH,"dependency_sources"=>sources,
        "native_status"=>request["status"],"native_solution_verified"=>true,"order_applied"=>request["application"],
        "wall_seconds"=>request["total_wall_seconds"],"completed_jobs"=>PM.metrics(app)["completed_jobs"],
        "python_required"=>false,"network_required"=>false)
    output=isempty(ARGS) ? joinpath(ROOT,"test","artifacts","portable-proof.json") : ARGS[1]
    PM.writejson(output,report)
    println("PASS: relocated folder, bundled Julia/depot, offline native solve, HTTP clock, priority application, completion")
finally
    PM.stop_server!(app)
end
