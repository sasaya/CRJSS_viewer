"""Normalize native configurations or the W/R/N/V/L/U route format."""
function normalize_config(data::AbstractDict)
    haskey(data, "machines") && return deepcopy(data)
    haskey(data, "W") || throw(ArgumentError("machines または W/R/N/V/L/U形式の入力が必要です"))
    positive_int(x, label) = x isa Integer && !(x isa Bool) && 1 <= x <= typemax(Int) ? Int(x) :
        throw(ArgumentError("$label は正の整数で指定してください"))
    stations = required(data, "W")
    stations isa AbstractVector && !isempty(stations) || throw(ArgumentError("W は機械番号の配列で指定してください"))
    ids = [positive_int(x, "W") for x in stations]
    length(unique(ids)) == length(ids) || throw(ArgumentError("W の機械番号が重複しています"))
    routes = positive_int(required(data, "R"), "R")
    raw_n = required(data, "N")
    raw_n isa AbstractVector && length(raw_n) == routes || throw(ArgumentError("N はR個の工程数で指定してください"))
    counts = [positive_int(x, "N") for x in raw_n]
    capacity = get(data, "Capacity", Dict{String,Any}())
    capacity isa AbstractDict || throw(ArgumentError("Capacity はオブジェクトで指定してください"))
    groups = Dict{String,Any}()
    occupied = Set{Int}()
    for (station, value) in capacity
        String(station) in string.(ids) || throw(ArgumentError("Capacity に未知の機械があります: $station"))
        n = positive_int(value, "Capacity[$station]")
        n <= 10000 || throw(ArgumentError("Capacity は10000以下で指定してください"))
        n == 1 && continue
        base = parse(Int, String(station))
        base <= typemax(Int)-n+1 || throw(ArgumentError("Capacity の機械番号が範囲を超えています"))
        members = collect(base:base+n-1)
        isempty(intersect(occupied, Set(members))) || throw(ArgumentError("Capacity の機械グループが重複しています: $station"))
        union!(occupied, members)
        groups["M$base"] = ["M$id" for id in members]
    end
    ids = unique(vcat(ids, sort(collect(occupied))))
    options = get(data, "import_options", Dict{String,Any}())
    options isa AbstractDict || throw(ArgumentError("import_options はオブジェクトで指定してください"))
    processing = get(options, "processing_time", "lower")
    processing in ("lower", "upper", "midpoint") || throw(ArgumentError("processing_time は lower / upper / midpoint で指定してください"))
    copies = positive_int(get(options, "copies_per_route", 1), "copies_per_route")
    handling = number(get(options, "handling_time", 20), "handling_time")
    scale = number(get(options, "seconds_per_unit", 2), "seconds_per_unit")
    function matrix(key, minimum_rows)
        rows = required(data, key)
        rows isa AbstractVector && length(rows) >= minimum_rows || throw(ArgumentError("$key の行数が不足しています"))
        all(row isa AbstractVector && length(row) >= routes for row in rows[1:minimum_rows]) ||
            throw(ArgumentError("$key の各行にはR個の値が必要です（外側=工程、内側=品種）"))
        rows
    end
    v = matrix("V", maximum(counts) + 1)
    lo, hi = matrix("L", maximum(counts)), matrix("U", maximum(counts))
    d = haskey(data, "D") ? matrix("D", max(0, maximum(counts)-1)) : nothing
    e = get(data, "E", nothing)
    if e !== nothing
        e isa AbstractVector && length(e) >= maximum(ids) &&
            all(row isa AbstractVector && length(row) >= maximum(ids) for row in e[1:maximum(ids)]) ||
            throw(ArgumentError("E は機械番号で参照できる移動時間行列（行=移動元、列=移動先）で指定してください"))
    end
    travel = Dict{String,Any}()
    for from in ids
        travel["M$from"] = Dict{String,Any}("M$to" => (from == to ? 0.0 : handling +
            (e === nothing ? scale * abs(from-to) : number(e[from][to], "E[$from][$to]"))) for to in ids)
    end
    jobs = Any[]
    for r in 1:routes
        route = [positive_int(v[i][r], "V[$i][$r]") for i in 1:counts[r]+1]
        all(id in ids for id in route) || throw(ArgumentError("品種$r のVにWにない機械が含まれています"))
        route[end] == route[end-1] || throw(ArgumentError("品種$r のV[N+1]は終端確認としてV[N]と同じ機械にしてください"))
        ops = Any[]
        for i in 1:counts[r]
            lower, upper = number(lo[i][r], "L[$i][$r]"), number(hi[i][r], "U[$i][$r]")
            lower <= upper || throw(ArgumentError("L[$i][$r] は U[$i][$r] 以下にしてください"))
            duration = processing == "lower" ? lower : processing == "upper" ? upper : lower / 2 + upper / 2
            op = Dict{String,Any}("machine" => "M$(route[i])", "duration" => duration)
            if i > 1 && d !== nothing
                op["travel_before"] = route[i-1] == route[i] ? 0.0 : number(d[i-1][r], "D[$(i-1)][$r]")
            end
            push!(ops, op)
        end
        for copy_index in 1:copies
            id = copies == 1 ? "J$r" : "J$(r)_$(copy_index)"
            push!(jobs, Dict("id" => id, "operations" => deepcopy(ops)))
        end
    end
    count = transport_count(get(options, "transport_count", get(data, "transport_count", 1)))
    Dict{String,Any}("machines" => ["M$id" for id in ids], "machine_groups" => groups, "jobs" => jobs, "travel_times" => travel, "transport_count" => count,
        "faults" => deepcopy(get(data, "faults", Dict("mode" => "none"))),
        "events" => deepcopy(get(data, "events", Any[])),
        "input_info" => Dict("format" => "W/R/N/V/L/U", "machine_groups" => deepcopy(groups), "route_count" => routes, "stage_counts" => counts,
            "copies_per_route" => copies, "processing_time" => processing,
            "travel_rule" => d !== nothing ? "D（工程・品種別）" : e !== nothing ? "異なる機械: handling_time + E[from][to]" : "異なる機械: handling_time + seconds_per_unit × |機械番号差|",
            "handling_time" => handling, "seconds_per_unit" => scale,
            "note" => "各品種を有限のジョブとして実行。L/Uから固定処理時間を選択。搬送台数の上限を適用。周期最適化・滞留上限・搬送機の空移動・衝突制約は適用しません。"))
end

function read_config_file(path::AbstractString; import_options=nothing)
    isfile(path) || throw(ArgumentError("設定ファイルが見つかりません: $path"))
    data = try
        JSON3.read(read(path, String), Dict{String,Any})
    catch
        throw(ArgumentError("設定ファイルは有効なJSONオブジェクトで指定してください"))
    end
    import_options !== nothing && (data["import_options"] = import_options)
    config = normalize_config(data)
    if haskey(config, "input_info")
        config["input_info"]["source_file"] = abspath(path)
    end
    config
end
