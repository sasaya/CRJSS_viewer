# Incremental CP-SAT log progress. Bound-only updates do not create a solution
# callback; consume their official solver log without changing stopping rules.
mutable struct NativeProgressReader
    path::String
    position::Int64
    partial::String
    bound::Union{Nothing,Float64}
    period::Union{Nothing,Float64}
    logged_seconds::Float64
end
NativeProgressReader(path)=NativeProgressReader(path,0,"",nothing,nothing,0.0)
function read_native_progress!(reader;elapsed=0.0)
    if isfile(reader.path)
        open(reader.path,"r") do io
            seekend(io);size=position(io)
            if size<reader.position
                reader.position=0;reader.partial=""
            end
            seek(io,reader.position)
            text=reader.partial*String(read(io))
            reader.position=position(io)
            lines=split(text,'\n';keepempty=true);reader.partial=pop!(lines)
            for line in lines
                matched=match(r"^#(?:Bound|\d+)\s+([\d.]+)s\s+best:([^\s]+)\s+next:\[([^,\]]+)",strip(line))
                matched===nothing && continue
                seconds=tryparse(Float64,matched[1]);period=tryparse(Float64,matched[2]);bound=tryparse(Float64,matched[3])
                seconds!==nothing && (reader.logged_seconds=max(reader.logged_seconds,seconds))
                period!==nothing && isfinite(period) && (reader.period=reader.period===nothing ? period : min(reader.period,period))
                bound!==nothing && isfinite(bound) && (reader.bound=reader.bound===nothing ? bound : max(reader.bound,bound))
            end
        end
    end
    gap=reader.period===nothing || reader.bound===nothing ? nothing : max(0.0,100*(reader.period-reader.bound)/max(1,abs(reader.period)))
    Dict("period"=>reader.period,"bound"=>reader.bound,"gap_percent"=>gap,
        "solver_seconds"=>max(reader.logged_seconds,Float64(elapsed)),"source"=>"cp_sat_native_log")
end
