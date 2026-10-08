# Plutoのセルを周期的に再評価すると、ページのスクロール位置が動きます。
# この読取専用のローカル接続からブラウザーへ更新を渡し、セルの再評価をなくします。

struct HistoryFeed
    server::HTTP.Server
    url::String
    directory::String
end

function stop_history_feed!(feed::HistoryFeed)
    close(feed.server)
    return nothing
end

"""履歴フォルダーだけを公開する、127.0.0.1上の読取専用HTTP接続を作ります。"""
function start_history_feed(directory::AbstractString)
    folder=abspath(directory)
    isdir(folder) || error("履歴フォルダーがありません: $folder")
    token=string(uuid4())
    base="/"*token
    headers=["Content-Type"=>"application/json; charset=utf-8",
             "Cache-Control"=>"no-store", "Access-Control-Allow-Origin"=>"*"]
    function handler(request::HTTP.Request)
        request.method=="OPTIONS" && return HTTP.Response(204,
            ["Access-Control-Allow-Origin"=>"*", "Access-Control-Allow-Methods"=>"GET, OPTIONS",
             "Access-Control-Allow-Headers"=>"Content-Type", "Access-Control-Allow-Private-Network"=>"true"])
        request.method=="GET" || return HTTP.Response(405)
        path=split(String(request.target),'?';limit=2)[1]
        path==base*"/state" && return HTTP.Response(200,headers,
            isfile(joinpath(folder,"history.json")) ? read(joinpath(folder,"history.json"),String) :
            "{\"status\":\"PREPARING\",\"entries\":[],\"final\":null,\"error\":null}")
        # 数字だけを受け付け、履歴JSONに載るファイル名から図を読みます。
        match_result=match(Regex("^"*base*"/frame/([0-9]+)\$"),path)
        isnothing(match_result) && return HTTP.Response(404)
        index=tryparse(Int,match_result.captures[1])
        isnothing(index) && return HTTP.Response(404)
        manifest=joinpath(folder,"history.json")
        isfile(manifest) || return HTTP.Response(404)
        state=JSON.parsefile(manifest)
        index in eachindex(state["entries"]) || return HTTP.Response(404)
        entry=state["entries"][index]
        prefix=String(entry["prefix"])
        occursin(r"^incumbent_[0-9]{6}$",prefix) || return HTTP.Response(404)
        filename=joinpath(folder,prefix)
        isfile(filename*"_trajectory.svg") && isfile(filename*".svg") || return HTTP.Response(404)
        frame=merge(Dict(entry),Dict("trajectory"=>read(filename*"_trajectory.svg",String),
                                    "gantt"=>read(filename*".svg",String)))
        return HTTP.Response(200,headers,JSON.json(frame))
    end
    server=HTTP.serve!(handler,"127.0.0.1",0;listenany=true,verbose=false)
    return HistoryFeed(server,"http://127.0.0.1:"*string(HTTP.Servers.port(server))*base,folder)
end
