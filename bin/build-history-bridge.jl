using Pkg, SHA
const ROOT = normpath(joinpath(@__DIR__,".."))
const SOLVER_ROOT = joinpath(ROOT,"vendor","HoistScheduling")
const SOURCE = joinpath(SOLVER_ROOT,"vendor","history_bridge","observer.cc")
const BUILD = joinpath(SOLVER_ROOT,"vendor","history_bridge","build")
const EXECUTABLE = joinpath(BUILD,"hoist_observer.exe")
const COMPILER = joinpath(ROOT,"runtime","history-tools","mingw64","bin","g++.exe")
offline = ARGS == ["offline"]
Pkg.activate(SOLVER_ROOT)
if !isfile(COMPILER)
    offline && isfile(EXECUTABLE) || error("History bridge compiler is missing; run setup.ps1 online")
    println("Reusing the existing history bridge (offline)")
    exit()
end
package_root = dirname(dirname(Base.find_package("ORTools_jll")))
artifacts_toml = joinpath(package_root,"Artifacts.toml")
hash = Pkg.Artifacts.artifact_hash("ORTools",artifacts_toml)
hash === nothing && error("OR-Tools artifact is missing")
artifact = Pkg.Artifacts.artifact_path(hash)
# Rebuild if source, compiler, or the linked OR-Tools artifact changes.
fingerprint = bytes2hex(sha256(read(SOURCE))) * ":" * string(hash) * ":" *
              bytes2hex(sha256(read(COMPILER))) * ":" * bytes2hex(sha256(read(@__FILE__)))
stamp = joinpath(BUILD,"build-fingerprint.txt")
if isfile(EXECUTABLE) && isfile(stamp) && read(stamp,String) == fingerprint
    println("History bridge is already built")
    exit()
end
mkpath(BUILD)
temporary = joinpath(BUILD,"hoist_observer.pending.exe")
libraries = sort(filter(p->endswith(p,".dll.a"),readdir(joinpath(artifact,"lib");join=true)))
isempty(libraries) && error("OR-Tools import libraries are missing")
# Match the compile definitions exported by the artifact's ortoolsTargets.cmake.
command = `$COMPILER -std=c++17 -O2 -fmax-errors=5 -DNDEBUG -DOR_PROTO_DLL= -DUSE_MATH_OPT -DUSE_BOP -DUSE_GLOP -DUSE_PDLP -D__WIN32__ -I$(joinpath(artifact,"include")) $SOURCE -o $temporary -Wl,--start-group $libraries -Wl,--end-group`
println("Building the optimization history bridge...")
withenv("PATH"=>dirname(COMPILER)*";"*get(ENV,"PATH","")) do
    run(command)
end
mv(temporary,EXECUTABLE;force=true)
write(stamp,fingerprint)
println("History bridge ready")
