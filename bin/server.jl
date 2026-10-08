using JobShopSimProposedMethod
config=isempty(ARGS) ? joinpath(@__DIR__,"..","examples","default.json") : abspath(ARGS[1])
port=length(ARGS)>=2 ? parse(Int,ARGS[2]) : 8081
app=start_server(config;port)
println("統合アプリ: http://127.0.0.1:$port")
println("実験保存先: ",app.directory)
try
    wait(Condition())
catch err
    err isa InterruptException || rethrow()
finally
    stop_server!(app)
end
