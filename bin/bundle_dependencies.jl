# Maintenance utility: snapshot installed dependencies into the portable depot.
# The shipped application and setup do not run this utility or require a global depot.
using Pkg, TOML
const ROOT = normpath(joinpath(@__DIR__,".."))
copies=Dict{String,String}()
versions=Dict{String,String}()
function inside(path,base)
    p=replace(abspath(path),'\\'=>'/');b=replace(abspath(base),'\\'=>'/')
    startswith(lowercase(p),lowercase(b)*"/") || lowercase(p)==lowercase(b)
end
for project in (ROOT,joinpath(ROOT,"vendor","HoistScheduling"))
    Pkg.activate(project)
    for (uuid,info) in Pkg.dependencies()
        info.version!==nothing && (versions[info.name]=string(info.version))
        source=info.source
        source===nothing && continue
        for depot in DEPOT_PATH
            if inside(source,joinpath(depot,"packages"))
                copies[source]=joinpath("runtime","depot",relpath(source,depot))
            end
        end
        toml=joinpath(source,"Artifacts.toml")
        isfile(toml) || continue
        for name in keys(TOML.parsefile(toml))
            hash=Pkg.Artifacts.artifact_hash(name,toml)
            hash===nothing && continue
            artifact=Pkg.Artifacts.artifact_path(hash)
            isdir(artifact) || continue
            copies[artifact]=joinpath("runtime","depot","artifacts",string(hash))
        end
    end
end
for depot in DEPOT_PATH
    registries=joinpath(depot,"registries")
    isdir(registries) || continue
    for file in readdir(registries;join=true)
        basename(file) in ("General.toml","General.tar.gz") || continue
        copies[file]=joinpath("runtime","depot","registries",basename(file))
    end
    any(occursin("registries",p) for p in values(copies)) && break
end
manifest=joinpath(ROOT,"runtime","dependency-snapshot.toml")
open(manifest,"w") do io
    TOML.print(io,Dict("versions"=>versions,"paths"=>sort(collect(values(copies)))))
end
for (source,relative) in sort(collect(copies);by=last)
    dest=joinpath(ROOT,relative)
    ispath(dest) && continue
    mkpath(dirname(dest))
    cp(source,dest)
    println(relative)
end
println("Packaged ",length(copies)," dependency paths")
