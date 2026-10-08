using Pkg
const ROOT = normpath(joinpath(@__DIR__,".."))
using TOML
mode = isempty(ARGS) ? "offline" : only(ARGS)
mode in ("online", "offline") || error("Expected online or offline")
offline = mode == "offline"
Pkg.offline(offline)
expected = VersionNumber(TOML.parsefile(joinpath(ROOT,"Manifest.toml"))["julia_version"])
VERSION == expected || error("This project requires Julia $expected; running $VERSION")
expected_depot = joinpath(ROOT,"runtime","depot")
length(DEPOT_PATH) == 1 && normpath(only(DEPOT_PATH)) == normpath(expected_depot) ||
    error("Run setup.ps1 to use the project-local Julia depot")
# DLL alias search is scoped to this process and its precompile children.
Sys.iswindows() && (ENV["PATH"]=joinpath(ROOT,"runtime","windows_runtime")*";"*get(ENV,"PATH",""))
for project in (ROOT,joinpath(ROOT,"vendor","HoistScheduling"))
    Pkg.activate(project)
    Pkg.instantiate(;update_registry=!offline,allow_autoprecomp=false)
    if Sys.iswindows() && project != ROOT
        # ORTools_jll imports bz2-1.dll, but its Windows artifact ships libbz2.dll.
        package_root = dirname(dirname(Base.find_package("ORTools_jll")))
        artifacts_toml = joinpath(package_root,"Artifacts.toml")
        hash = Pkg.Artifacts.artifact_hash("ORTools",artifacts_toml)
        hash === nothing && error("No OR-Tools artifact for this platform")
        Pkg.Artifacts.ensure_artifact_installed("ORTools",artifacts_toml)
        source = joinpath(Pkg.Artifacts.artifact_path(hash),"bin","libbz2.dll")
        destination = joinpath(ROOT,"runtime","windows_runtime","bz2-1.dll")
        mkpath(dirname(destination))
        cp(source,destination;force=true)
    end
    Pkg.precompile(;strict=true)
end
# Catch missing native DLLs before reporting a successful installation.
include(joinpath(ROOT,"vendor","HoistScheduling","src","HoistScheduling.jl"))
println("Julia and OR-Tools ready ($mode)")
