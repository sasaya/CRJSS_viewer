module JobShopSimProposedMethod
using JobShopSim, HTTP, JSON3, SHA, Dates, UUIDs
const JS = JobShopSim
# Recompute paths when loading: cached @__DIR__ constants otherwise retain the
# precompile location after copying the complete application to another folder.
ROOT::String = ""
SOLVER_ROOT::String = ""
function __init__()
    global ROOT = pkgdir(@__MODULE__)
    global SOLVER_ROOT = joinpath(ROOT,"vendor","HoistScheduling")
end
wall() = Float64(time_ns())/1e9
readjson(path) = JSON3.read(read(path,String),Dict{String,Any})
function writejson(path, data)
    mkpath(dirname(path))
    open(path*".tmp", "w") do io; JSON3.write(io,data); end
    mv(path*".tmp",path;force=true)
end
function canonical(x)
    x isa AbstractDict && return "{"*join([JSON3.write(String(k))*":"*canonical(x[k]) for k in sort(collect(keys(x));by=string)],",")*"}"
    x isa AbstractVector && return "["*join(canonical.(x),",")*"]"
    JSON3.write(x)
end
problem_hash(x) = bytes2hex(sha256(canonical(x)))
include("TransferOrderExtractor.jl")
module SolverVerification
using JSON,Printf
include(joinpath(@__DIR__,"..","vendor","HoistScheduling","src","data.jl"))
include(joinpath(@__DIR__,"..","vendor","HoistScheduling","src","verification.jl"))
include(joinpath(@__DIR__,"..","vendor","HoistScheduling","src","plotting.jl"))
end
include("OptimizationTermination.jl")
include("InputPaths.jl")
include("JobProvenance.jl")
include("CycleConformance.jl")
include("TransferPriorityPolicy.jl")
include("OptimizerController.jl")
include("JobReleasePolicy.jl")
include("CyclicTimingPolicy.jl")
include("CyclicPatternReuse.jl")
include("IncrementalDelivery.jl")
include("SimulationStartup.jl")
include("Metrics.jl")
include("OptimizationHistory.jl")
include("WebServer.jl")
export start_server, stop_server!, Application, request!, cancel!, extract_order, metrics, save_experiment!
end
