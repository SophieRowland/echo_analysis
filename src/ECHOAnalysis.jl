module ECHOAnalysis

export
    # Metadata handling
    resolve_sampleID,
    resolve_letter_timepoint,
    breastfeeding,
    formulafeeding,
    firstkids,
    numberify,
    getmetadatum,
    getmetadata,
    metacolor,
    getfocusmetadata,

    #File Handling
    add_batch_info,
    merge_tables,

    # Startup Functions
    load_taxonomic_profiles,
    load_metadata,
    color1,
    color2,
    color3,
    color4,
    datatoml

using DataFrames
using CSV
using Colors
using ColorBrewer
using PrettyTables
using Pkg.TOML: parsefile

using Microbiome

include("metadata_handling.jl")
include("file_handling.jl")
include("startup.jl")

end  # module ECHOAnalysis
