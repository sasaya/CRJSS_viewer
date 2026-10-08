# Normalize explicit clipboard formats; never remove arbitrary interior text.
function unquote_input_path(path)
    first_quote=startswith(path,"\"");last_quote=endswith(path,"\"")
    first_quote==last_quote || throw(ArgumentError("パスの前後のダブルクォートが対応していません。ファイルのパスだけを指定してください。"))
    first_quote && length(path)<2 && throw(ArgumentError("パスのダブルクォートを確認してください。"))
    first_quote ? strip(chop(path;head=1,tail=1)) : path
end
function normalize_input_path(value)
    value isa AbstractString || throw(ArgumentError("path は文字列で指定してください"))
    path=strip(replace(String(value),r"^\ufeff+"=>""))
    startswith(path,"\"") && endswith(path,"\"") && length(path)>=2 && (path=unquote_input_path(path))
    columns=split(path,'\t';keepempty=true)
    if length(columns)==2 && occursin(r"^\d+$",strip(columns[1]))
        candidate=unquote_input_path(strip(columns[2]))
        occursin(r"^(?:[A-Za-z]:[\\/]|\\\\|/)",candidate) && (path=candidate)
    end
    path=String(unquote_input_path(path))
    isempty(path) && throw(ArgumentError("ファイルのパスを入力してください。例：data/input_data.json"))
    occursin(r"[\x00-\x1f\x7f]",path) && throw(ArgumentError("パスにタブ・改行などの制御文字、または表の余分な列が含まれています。ファイルのパスだけを指定してください。"))
    if Sys.iswindows()
        # Preserve the standard extended-length Windows path prefix.
        checked=startswith(path,"\\\\?\\") ? path[5:end] : path
        occursin(r"^[A-Za-z]:[^\\/]",checked) && throw(ArgumentError("ドライブ文字の直後には\\または/が必要です。例：D:\\folder\\input.json"))
        checked=replace(checked,r"^[A-Za-z]:"=>"")
        occursin(r"[<>\"|?*:]",checked) && throw(ArgumentError("Windowsのファイルパスに使えない文字が含まれています。番号や表の列を除き、ファイルのパスだけを指定してください。"))
    end
    path
end
function input_path(value)
    path=normalize_input_path(value)
    resolved=abspath(isabspath(path) ? path : joinpath(ROOT,path))
    regular=try
        isfile(resolved)
    catch err
        err isa SystemError || err isa Base.IOError || rethrow()
        throw(ArgumentError("ファイルのパスを確認できません。入力とアクセス権を確認してください：$resolved"))
    end
    regular || throw(ArgumentError("指定されたファイルが見つからないか、フォルダーが指定されています：$resolved"))
    resolved
end
function read_input_json(value)
    path=input_path(value)
    try
        readjson(path)
    catch err
        if err isa SystemError || err isa Base.IOError
            throw(ArgumentError("ファイルを読み込めません。パスとアクセス権を確認してください：$path（$(sprint(showerror,err))）"))
        elseif err isa ArgumentError || err isa EOFError
            throw(ArgumentError("ファイルをJSONとして読み込めません。JSONの形式を確認してください：$path（$(sprint(showerror,err))）"))
        end
        rethrow()
    end
end
