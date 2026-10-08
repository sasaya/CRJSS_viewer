using Pkg
const ROOT = normpath(joinpath(@__DIR__,".."))
Pkg.offline(true)
# DLL alias search is scoped to this process and its precompile children.
Sys.iswindows() && (ENV["PATH"]=joinpath(ROOT,"vendor","HoistScheduling","vendor","windows_runtime")*";"*get(ENV,"PATH",""))
for project in (ROOT,joinpath(ROOT,"vendor","HoistScheduling"))
    Pkg.activate(project)
    Pkg.instantiate(;update_registry=false,allow_autoprecomp=false)
    Pkg.precompile(;strict=true)
end
println("同梱環境の準備完了（オフライン）")
