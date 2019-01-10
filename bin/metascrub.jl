using ArgParse
using Logging
using LoggingExtras

using CSV
using DataFrames
using Dates


function parse_commandline()
    s = ArgParseSettings()

    @add_arg_table s begin
        # Logging Stuff
        "--debug", "-d"
            help = "Show @debug level logging messages"
            action= :store_true
        "--verbose", "-v"
            help = "Show @info level logging messages"
            action= :store_true
        "--quiet", "-q"
            help = "Only show @error logging messages"
            action= :store_true
        "--log", "-l"
            help = "Write logs to this file. Default - no file"
            default = nothing

        # Stuff to do
        "--delim"
            default = ","
        "--dry-run"
            help = "Show logging, but take no action. Most useful with --verbose"
            action= :store_true
        "--output", "-o"
            help = "Output for scrubbed file (defaults to overwriting input)"
            arg_type = String
        "--samples", "-s"
            help = "Path to sample metadata to be included (optional)"
            default = nothing
            arg_type = String
        "input"
            help = "Table to be scrubbed. By default, this will be overwritten"
            required = true
    end

    return parse_args(s)
end

function setup_logs!(loglevel, logpath; dryrun=false)
    glog = SimpleLogger(stderr, loglevel)
    if logpath === nothing || dryrun
        global_logger(glog)
    else
        logpath = abspath(expanduser(logpath))
        global_logger(DemuxLogger(
            FileLogger(logpath, min_level=loglevel),
            glog, include_current_global=false))
    end
end

function rowmissingfilter(r::DataFrameRow)
    if all(ismissing, values(r))
        @debug "All entries for row $(DataFrames.row(r)) are missing, removing"
        return false
    else
        return true
    end
end

function splitheader(h::AbstractString)
    h = replace(h, " "=>"_")
    return Tuple(String.(split(h, "::")))
end

function splitheader(h::Symbol)
    h = string(h)
    return splitheader(h)
end

function getsubtable(df, parent)
    indices = findall(x-> occursin(parent, replace(string(x), " "=>"_")), names(df))
    table = copy(df[indices])
    headers = map(x-> splitheader(x)[2], names(table))
    names!(table, Symbol.(headers), makeunique=true)

    return table
end


function elongate(df; idcol=:studyID, tpcol=:timepoint)
    table = copy(df)
    if tpcol != :timepoint
        rename!(table, tpcol=>:timepoint)
    end

    table = melt(table, [idcol, tpcol], variable_name=:metadatum)
    filter!(r-> !ismissing(r[tpcol]), table)
    return table
end

const special_cases = Set(["Fecal_with_Ethanol", "FecalSampleCollection", "TimepointInfo", "LeadHemoglobin","Delivery"])

function customprocess!(table, parent)
    !in(parent, special_cases) && return table

    if parent == "Fecal_with_Ethanol" || parent == "FecalSampleCollection"
        for n in names(table)
            s = string(n)
            if occursin("Fecalwethanol", s)
                s = replace(s, "Fecalwethanol"=>"")
            end
            s = replace(s, "#"=> "Num")
            rename!(table, n=> Symbol(s))
        end
        parent == "Fecal_with_Ethanol" && rename!(table, :CollectionDate=>:date, :CollectionNum=>:timepoint)
        parent == "FecalSampleCollection" && rename!(table, :collectionDate=>:date, :collectionNum=>:timepoint)

        table[:date] = map(x-> ismissing(x) ? missing : DateTime(x, dateformat"m/d/y"),  table[:date])

    elseif parent == "TimepointInfo"
        table[:date] = map(x-> ismissing(x) ? missing : DateTime(x, dateformat"m/d/y"),  table[:scanDate])
        deletecols!(table, :scanDate)
    elseif parent == "LeadHemoglobin"
        rename!(table, :testNumber=>:timepoint)
    elseif parent == "Delivery"
        table[:birthType] = let bt = Union{String,Missing}[]
            for t in table[:birthType]
                if ismissing(t)
                    push!(bt, missing)
                elseif !occursin(r"([cC]esarean|[vV]aginal)", t)
                    push!(bt, t)
                elseif occursin(r"[cC]esarean", t)
                    push!(bt, "Cesarean")
                elseif occursin(r"[vV]aginal", t)
                    push!(bt, "Vaginal")
                else
                    @error "something went wrong" t
                end
            end
            bt
        end
    else
        @warn "No processing code for special case $parent"
    end
    return table
end


function main(args)

    if args["debug"]
        loglevel = Logging.Debug
    elseif args["verbose"]
        loglevel = Logging.Info
    elseif args["quiet"]
        loglevel = Logging.Error
    else
        loglevel = Logging.Warn
    end
    setup_logs!(loglevel, args["log"], dryrun = args["dry-run"])

    inputpath = expanduser(args["input"]) |> abspath
    @info "Reading file from $inputpath"
    meta = CSV.File(inputpath, delim=args["delim"]) |> DataFrame

    parents = map(n->splitheader(n)[1], names(meta)) |> unique

    @info "Processing parent tables" parents

    tables = DataFrame(studyID=String[],
                        timepoint=Union{Int,Missing}[],
                        metadatum=String[],
                        value=Any[],
                        parent_table=String[])

    for p in parents
        subtable = getsubtable(meta, p)
        @info "Table Name: $p"

        # Remove columns where all values are missing
        for n in names(subtable)
            if all(ismissing, subtable[n])
                @info "All entries for subtable $p column $n are missing, removing"
                deletecols!(subtable, n)
            end
        end

        # Remove rows where all values are missing
        filter!(rowmissingfilter, subtable)

        # Rename columns to remove double :: and spaces
        for name in names(subtable)
            if occursin(" ", string(name))
                new_name = replace(string(name), " "=>"_")
                @info "Changing column $name to $new_name"
                rename!(subtable, name => new_name)
            end
        end

        @debug names(subtable)
        customprocess!(subtable, p)

        if !any(n-> n == :timepoint, names(subtable))
            @warn "No timpoint column detected for $p, treating as all-timepoint variable"
            subtable[:timepoint] = 0
        end
        subtable = elongate(subtable, idcol=:studyID, tpcol=:timepoint)
        subtable[:parent_table] = p

        tables = vcat(tables, subtable)
    end

    args["output"] === nothing ? outputpath = inputpath : outputpath = abspath(expanduser(args["output"]))

    @info "Writing scrubbed file to $outputpath"
    if !args["dry-run"]
        CSV.write(outputpath, tables, delim=args["delim"])
    else
        @info "Just kidding! this is a dry run"
    end
end


let args = parse_commandline()
    main(args)
end
#
#
# ## Testing
#
# args = Dict(
#             "input" => "~/Desktop/all.csv",
#             "output" => "~/Desktop/scrubbed.csv",
#             "verbose" => true,
#             "log" => "/Users/ksb/Desktop/scrub.log",
#             "debug" => false,
#             "quiet"=> false,
#             "delim"=>",",
#             "dry-run"=>false
#             )
# main(args)