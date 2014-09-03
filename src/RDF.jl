module RDF

export
    # types
    Graph,
    IRI,
    Literal,
    # functions (graph manipulation)
    push!,
    pop!,
    # functions (graph loading/deserialization)
    load_ntriples!,
    load_nquads!,
    load_turtle!,
    # functions (graph serialization)
    ntriples,
    nquads,
    turtle,
    # functions (utility/convenience)
    blanknode!
    # functions at Base scope (iterator support)
    # Base.start
    # Base.done
    # Base.next

RDF_LANG = [ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
             'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
             'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
             '-' ]

type IRI
    iri::String
end

type Literal
    value::Union(Bool,Number,String)
    iri::Union(IRI,Nothing)
    langtag::Union(String,Nothing)

    Literal(value::Union(Bool,Number,String)) = new(value,
                                                    nothing,
                                                    nothing)
    Literal(value::Union(Bool,Number,String), iri::IRI) = new(value,
                                                              iri,
                                                              nothing)
    Literal(value::Union(Bool,Number,String), langtag::String) = new(value,
                                                                     nothing,
                                                                     langtag)
    Literal(value::Union(Bool,Number,String),
            iri::Union(IRI,Nothing),
            langtag::Union(String,Nothing)) = new(value,
                                                  iri,
                                                  langtag)
end

type AnonymousBlankNode
    identifier::Uint64
end

type LabeledBlankNode
    label::String
end

type Graph
    name::IRI
    base::IRI
    prefixes::Dict{String,IRI}
    blanknode::Uint64
    size::Int64
    statements::Dict{String,Dict{String,Set{Union(Literal,IRI)}}}

    Graph(name::IRI) = new(name,
                           IRI(""),
                           Dict{String,IRI}(),
                           0,
                           0,
                           Dict{String,Dict{String,Set{Union(Literal,IRI)}}}())
end

# TODO Keeping arrays instead of iterators is memory inefficient.
type GraphIterator
    subjects::Array{String}
    predicates::Array{String}
    objects::Array{Union(Literal,IRI)}
    predicates_under_subject::Any
    current_subject::Any
    current_predicate::Any
end

# String conversion of IRIs.
function Base.string(iri::IRI)
    return iri.iri
end

function ==(left::IRI,
            right::IRI)
    return left.iri == right.iri
end
function blanknode!(graph::Graph)
    iri = IRI("bn://" * string(graph.blanknode))
    graph.blanknode += 1
    return iri
end

function load_ntriples!(graph::Graph,
                        rdf_in::String)
    subject, predicate, object = split(rdf_in, r"\s+", 3)
    # Get rid of the trailing dot, if it's there, as well as comments.
    object = replace(object, r"\s*?\.\s*(#.*)?$", "")

    # Handle comments, @base/BASE as well as @prefix/PREFIX meta-information:
    if ismatch(r"\s*#", subject)
        # Comment line. Ignore.
        return
    elseif beginswith(subject, "@base ") || beginswith(subject, "BASE ")
        graph.base = IRI(predicate[2:length(predicate) - 1])
        return
    elseif beginswith(subject, "@prefix ") || beginswith(subject, "PREFIX ")
        graph.prefixes[predicate] = IRI(object[2:length(object) - 1])
        return
    end

    # Extract object type annotations/language annotation:
    object_type = nothing
    object_language = nothing
    if ismatch(r"\"^^<.+>$", object)
        object, object_type = rsplit(object, "^^", 2)
        object_type = IRI(object_type[2:length(object_type) - 1])
    elseif ismatch(r"\"@.+$", object)
        object, object_language = rsplit(object, "@", 2)
    end

    # TODO N-Triples syntax checking.

    # Conversion of an object to its appropriate type:
    if beginswith(object, "<") && endswith(object, ">")
        object = Literal(IRI(object[2:length(object) - 1]), object_type, object_language)
    elseif beginswith(object, "\"") && endswith(object, "\"")
        object = Literal(object[2:length(object) - 1], object_type, object_language)
    elseif ismatch(r"^\d+\.\d+$")
        object = Literal(float(object), object_type, object_language)
    elseif ismatch(r"^\d+$", object)
        object = Literal(int(object), object_type, object_language)
    elseif object == "true"
        object = Literal(true, object_type, object_language)
    elseif object == "false"
        object = Literal(false, object_type, object_language)
    else
        # TODO Error handling.
    end

    # Object type and language annotations are currently not captured.
    push!(graph,
          subject[2:length(subject) - 1],
          predicate[2:length(subject) - 1],
          object)
end

function load_ntriples!(graph::Graph,
                        rdf_in::IO)
    for line in eachline(rdf_in)
        load_ntriples!(graph, line)
    end
end

function load_nquads!(graphs::Array{Graph},
                      in::String)
    # Approach: remove the graph part, then use N-Triples loading:
    # TODO
end

function load_turtle!(graph::Graph,
                      ttl_in::String)
    load_turtle!(IOBUffer(ttl_in))
end

function load_turtle!(graph::Graph,
                      ttl_in::IO)
    # States:
    #   idle    (initial state)
    #   comment (# until EOL)
    #   meta    (for @base/BASE and @prefix/PREFIX)
    #   subject
    #   polist  (predicate/object list)
    #   bnplist (blank-node property list)
    #   verb
    #   iri
    #   olist
    #   object
    #   abbrev
    state = Symbol[ :statement ]
    terminals = Any[]
    token = Char[]

    # Fill lookahead. Be aware of ultra-short TTL documents, which cannot
    # contain any information (too short for even blank node usage), but
    # are valid nonetheless.
    lookahead = Char[]
    lookahead_size = 6
    for n in range(1, lookahead_size)
        if eof(ttl_in)
            return
        end
        Base.push!(lookahead, read(ttl_in, Char))
    end

    # input: character that is about to be consumed, which then triggers
    #        a shift of the lookahead, or it sets off a state change
    # consumed:
    #   1. number of characters that should be added to the lookahead
    #   2. number of characters that were consumed and need to be replaced
    #      on the following iterations
    input = ' '
    consumed = 1
    while !eof(ttl_in)
        while consumed > 0
            input = shift!(lookahead)
            Base.push!(lookahead, read(ttl_in, Char))
            consumed -= 1
        end
        while (consumed = ttl_next!(graph, state, terminals, token, input, lookahead)) == 0
        end
    end

    for n in range(1, lookahead_size)
        input = shift!(lookahead)
        Base.push!(lookahead, ' ')
        while (consumed = ttl_next!(graph, state, terminals, token, input, lookahead)) == 0
        end
    end
    return terminals
end

function ttl_next!(graph::Graph,
                   state::Array{Symbol},
                   terminals::Array{Any},
                   token::Array{Char},
                   input::Char,
                   lookahead::Array{Char})
    """
        Returns:

        *  true  : input has been consumed
        *  false : input has not been consumed
    """
    current_state = last(state)

    # println(join(state, " <- ") * " : " * string(input) * " ~ " * string(lookahead))

    if !(current_state in [ :iriref,
                            :iripname,
                            :comment,
                            :skipnb,
                            :stringd,
                            :strings,
                            :stringdl3,
                            :stringdl4,
                            :stringdl5,
                            :stringsl3,
                            :stringsl4,
                            :stringsl5 ])
        if input == '#'
            # Skip comments to end of line.
            transition!(state, [ current_state, :comment ])
            return 1
        elseif input in [ ' ', '\r', '\n', '\t' ]
            # Skip whitespace.
            return 1
        end
    end

    if current_state == :skipnb
        if input in [ ' ', '\r', '\n', '\t' ]
            transition!(state)
            return 1
        else
            return 1
        end
    elseif current_state == :iri
        if input == '<'
            transition!(state, :iriref)
            return 1
        else
            transition!(state, :iripname)
            return 0
        end
    elseif current_state == :iripname
        if input in [ ' ', '\r', '\n', '\t' ] # add '<' or '_' (can't return true then, not repeated below)?
            reduce!(graph, terminals, current_state, token)
            transition!(state)
            return 1
        else
            Base.push!(token, input)
            return 1
        end
    elseif current_state == :iriref
        if input == '>'
            reduce!(graph, terminals, current_state, token)
            transition!(state)
            return 1
        else
            Base.push!(token, input)
            return 1
        end
    elseif current_state == :stringd
        ttl_string!(graph, state, terminals, token, input, lookahead, '"', uint8(0))
    elseif current_state == :strings
        ttl_string!(graph, state, terminals, token, input, lookahead, '\'', uint8(0))
    elseif current_state == :integer # :integer can become :decimal or :float
        if input in [ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' ]
            Base.push!(token, input)
            return 1
        elseif input in [ ' ', '\r', '\n', '\t' ]
            reduce!(graph, terminals, current_state, token)
            transition!(state)
            return 1
        else
            transition!(state, :decimal)
            return 0
        end
    elseif current_state == :decimal
        if input in [ 'e', 'E' ]
            transition!(state, :double)
            return 0
        elseif input in [ ' ', '\r', '\n', '\t' ]
            reduce!(graph, terminals, current_state, token)
            transition!(state)
            return 1
        else
            Base.push!(token, input)
            transition!(state)
            return 1
        end
    elseif current_state == :double
        if input in [ ' ', '\r', '\n', '\t' ]
            reduce!(graph, terminals, current_state, token)
            transition!(state)
            return 1
        else
            Base.push!(token, input)
            return 1
        end
    elseif current_state == :subject
        if input == '<'
            transition!(state, :iri)
            return 0
        elseif input == '('
            transition!(state, :collection)
            return 1
        elseif input in [ '_', '[' ]
            transition!(state, bnode)
            return 0
        else
            transition!(state, :iri)
            return 0
        end
    elseif current_state == :object
        if input == '<'
            transition!(state, :iri)
            return 0
        elseif input == '('
            transition!(state, :collection)
            return 1
        elseif input == '['
            transition!(state, :bnplist)
            return 1
        elseif input == '_'
            transition!(state, :bnode) # next: colon, ':'
            return 1
        elseif input in [ '"', '\'', '+', '-', '.', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' ]
            transition!(state, :literal)
            return 0
        elseif input == 'f' && lookahead[1] == 'a' && lookahead[2] == 'l' && lookahead[3] =='s' && lookahead[4] == 'e' && lookahead[5] in [ '.', '#', ' ', '\r', '\n', '\t' ]
            transition!(state, :literal)
            return 0
        elseif input == 't' && lookahead[1] == 'r' && lookahead[2] == 'u' && lookahead[3] =='e' && lookahead[4] in [ '.', '#', ' ', '\r', '\n', '\t' ]
            transition!(state, :literal)
            return 0
        else
            transition!(state, :iri)
            return 0
        end
    elseif current_state == :triples
        if input == '['
            transition!(state, [ :polistopt, :bnplist ])
            return 1
        else
            transition!(state, [ :polist, :subject ])
            return 0
        end
    elseif current_state == :literal
        if input == '"'
            # TODO Can be optimized by nesting ifs.
            if lookahead[1] == '"' && lookahead[2] == '"' && lookahead[3] =='"' && lookahead[4] == '"'
                transition!(state, [ :langtypetag, :stringdl5 ])
                return 5
            elseif lookahead[1] == '"' && lookahead[2] == '"' && lookahead[3] =='"'
                transition!(state, [ :langtypetag, :stringdl4 ])
                return 4
            elseif lookahead[1] == '"' && lookahead[2] == '"'
                transition!(state, [ :langtypetag, :stringdl3 ])
                return 3
            else
                transition!(state, [ :langtypetag, :stringd ])
                return 1
            end
        elseif input == '\''
            # TODO Can be optimized by nesting ifs.
            if lookahead[1] == '\'' && lookahead[2] == '\'' && lookahead[3] =='\'' && lookahead[4] == '\''
                transition!(state, [ :langtypetag, :stringsl5 ])
                return 5
            elseif lookahead[1] == '\'' && lookahead[2] == '\'' && lookahead[3] =='\''
                transition!(state, [ :langtypetag, :stringsl4 ])
                return 4
            elseif lookahead[1] == '\'' && lookahead[2] == '\''
                transition!(state, [ :langtypetag, :stringsl3 ])
                return 3
            else
                transition!(state, [ :langtypetag, :strings ])
                return 1
            end
        elseif input in [ '+', '-', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' ]
            transition!(state, :integer)
            return 0
        elseif input == '.'
            transition!(state, :decimal)
            return 0
        elseif input == 't'
            reduce!(graph, terminals, :true, token)
            transition!(state, :skipnb)
            return 1
        elseif input == 'f'
            reduce!(graph, terminals, :false, token)
            transition!(state, :skipnb)
        else
            error("literal starts with unexpected character: " * string(input))
        end
    elseif current_state == :delim
        if input == '.'
            transition!(state)
            return 1
        else
            error("delimiter missing ('.')")
        end
    elseif current_state == :compile
        if input == '.'
            polist = Base.pop!(terminals)
            subjects = Base.pop!(terminals)
            if isa(subjects, IRI)
                for po in polist
                    predicate, objects = po
                    predicate = IRI(predicate)
                    for object_list in objects
                        for object in object_list
                            push!(graph, subjects, predicate, object)
                        end
                    end
                end
                Base.push!(terminals, AnonymousBlankNode(graph.blanknode += 1))
            else
                # TODO
                error("only handles IRI subjects for now")
            end
            transition!(state)
            return 1
        else
            error("delimiter missing ('.') for compilation")
        end
    elseif current_state == :verb
        if input == 'a' && lookahead[1] in [ ' ', '\r', '\n', '\t' ]
            reduce!(graph, terminals, current_state, token) # token ignored
            transition!(state)
            return 1
        else
            transition!(state, :iri)
            return 0
        end
    elseif current_state == :lang
        if input in RDF_LANG
            Base.push!(token, input)
            return 1
        else
            reduce!(graph, terminals, current_state, token)
            transition!(state)
            return 0
        end
    elseif current_state == :langtypetag
        if input == '@'
            transition!(state, :lang)
            return 1
        elseif input == '^' && lookahead[1] == '^'
            transition!(state, :typestart)
            return 1
        else
            transition!(state)
            return 0
        end
    elseif current_state == :typestart
        # Already checked that a caret is in this place; hence, proceed:
        transition!(state, [ :typeiri, :iri ])
        return 1
    elseif current_state == :typeiri
        typeiri = Base.pop!(terminals)
        last(terminals).iri = typeiri
        transition!(state)
        return 0
    elseif current_state == :bnode
        # TODO
        error("TODO bnode implementation")
    elseif current_state == :olist
        Base.push!(terminals, Any[])
        transition!(state, [ :olistiter, :object ])
        return 0
    elseif current_state == :olistiter
        object = Base.pop!(terminals)
        Base.push!(last(terminals), object)
        if input == ','
            transition!(state, [ :olistiter, :object ])
            return 1
        else
            transition!(state)
            return 0
        end
    elseif current_state == :collection
        if input == ')'
            transition!(state)
        else
            transition!(state, [ :collection, :object ])
        end
    elseif current_state == :polist
        Base.push!(terminals, Dict{String, Set{Any}}())
        transition!(state, [ :polistiter, :olist, :verb ])
        return 0
    elseif current_state == :polistiter
        objects = Base.pop!(terminals)
        predicate = string(Base.pop!(terminals))
        polist = last(terminals)
        if !haskey(polist, predicate)
            polist[predicate] = Set{Any}()
        end
        Base.push!(polist[predicate], objects)
        if input == ';'
            transition!(state, [ :polistiter, :olist, :verb ])
            return 1
        else
            transition!(state)
            return 0
        end
    elseif current_state == :polistopt
        if input == '.'
            transition!(state)
            return 0
        else
            transition!(state, [ :polistiter, :olist, :verb ])
            return 0
        end
    elseif current_state == :stringdl3
        ttl_string!(graph, state, terminals, token, input, lookahead, '"', uint8(3))
    elseif current_state == :stringdl4
        ttl_string!(graph, state, terminals, token, input, lookahead, '"', uint8(4))
    elseif current_state == :stringdl5
        ttl_string!(graph, state, terminals, token, input, lookahead, '"', uint8(5))
    elseif current_state == :stringsl3
        ttl_string!(graph, state, terminals, token, input, lookahead, '\'', uint8(3))
    elseif current_state == :stringsl4
        ttl_string!(graph, state, terminals, token, input, lookahead, '\'', uint8(4))
    elseif current_state == :stringsl5
        ttl_string!(graph, state, terminals, token, input, lookahead, '\'', uint8(5))
    elseif current_state == :statement
        # TODO check whether separators in the lookahead are correct
        if input in [ '@', 'p', 'P', 'b', 'B' ] &&
           (input == '@' ||
            lowercase(lookahead[1]) == 'r' &&
                lowercase(lookahead[2]) == 'e' &&
                lowercase(lookahead[3]) == 'f' &&
                lowercase(lookahead[4]) == 'i' &&
                lowercase(lookahead[5]) == 'x' &&
                lookahead[6] in [ ' ', '\r', '\n', '\t' ] ||
            lowercase(lookahead[1]) == 'a' &&
                lowercase(lookahead[2]) == 's' &&
                lowercase(lookahead[3]) == 'e' &&
                lookahead[4] in [ ' ', '\r', '\n', '\t' ]
           )
            transition!(state, [ :statement, :directive ])
            return 0
        elseif input == '#'
            transition!(state, [ :statement, :comment ])
            return 1
        else
            transition!(state, [ :statement, :compile, :triples ])
            return 0
        end
    elseif current_state == :directive
        if input == '@'
            transition!(state, :prefixid)
            return 1
        else
            transition!(state, :sparql)
            return 0
        end
    elseif current_state == :prefixid
        if input == 'b'
            transition!(state, [ :base, :delim, :iri, :skipnb ])
            return 1
        else
            transition!(state, [ :prefix, :delim, :iri, :pname, :skipnb ])
            return 1
        end
    elseif current_state == :sparql
        if input in [ 'b', 'B' ]
            transition!(state, [ :base, :iri, :skipnb ])
            return 1
        else
            transition!(state, [ :prefix, :iri, :pname, :skipnb ])
            return 1
        end
    elseif current_state == :comment
        if input == '\n' || input == '\r'
            transition!(state)
            return 1
        else
            return 1
        end
    elseif current_state == :base
        graph.base = Base.pop!(terminals)
        transition!(state)
        return 0
    elseif current_state == :prefix
        mapped_uri = Base.pop!(terminals)
        prefix = Base.pop!(terminals)
        graph.prefixes[prefix] = mapped_uri
        transition!(state)
        return 0
    elseif current_state == :pname
        if input == ':'
            reduce!(graph, terminals, current_state, token)
            transition!(state)
        else
            Base.push!(token, input)
        end
        return 1
    else
        # TODO invalid current_state
        error("invalid current_state in transition! of the universal RDF parser; bogus current_state: " * string(current_state))
    end
end

function ttl_string!(graph::Graph,
                     state::Array{Symbol},
                     terminals::Array{Any},
                     token::Array{Char},
                     input::Char,
                     lookahead::Array{Char},
                     eos::Char,
                     repeat::Uint8)
    if input == '\\'
        Base.push!(token, input)
        transition!(state, [ pop!(state), :escape ])
    elseif input == eos
        if repeat > 0 && prefixn(lookahead, eos, uint8(repeat - 1))
            reduce!(graph, terminals, last(state), token)
            transition!(state)
        elseif repeat == 0
            reduce!(graph, terminals, last(state), token)
            transition!(state)
        else
            Base.push!(token, input)
        end
    else
        Base.push!(token, input)
    end
    return true
end

function prefixn(characters::Array{Char},
                 prefix::Char,
                 n::Uint8)
    current_n = n
    while current_n > 0
        if characters[current_n] != prefix
            return false
        end
        current_n -= 1
    end
    return true
end

function reduce!(graph::Graph,
                 terminals::Array{Any},
                 state::Symbol,
                 token::Array{Char})
    if state == :iriref
        string_uri = utf8(token)
        if ismatch(r"^[a-zA-Z0-9_]+://", string_uri)
            Base.push!(terminals, IRI(string_uri))
        else
            Base.push!(terminals, IRI(string(graph.base) * string_uri))
        end
    elseif state == :iripname
        prefix, name = split(utf8(token), ':', 2)
        Base.push!(terminals, IRI(string(graph.prefixes[prefix]) * name))
    elseif state == :pname
        Base.push!(terminals, utf8(token))
    elseif state == :verb # predicate 'a'
        Base.push!(terminals, IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"))
    elseif state == :stringd || state == :strings
        Base.push!(terminals, Literal(utf8(token), nothing, nothing))
    elseif state == :integer
        Base.push!(terminals, Literal(uint(ascii(token)), nothing, nothing))
    elseif state == :decimal
        Base.push!(terminals, Literal(float64(ascii(token)), nothing, nothing))
    elseif state == :double
        Base.push!(terminals, Literal(float64(ascii(token)), nothing, nothing))
    elseif state == :true
        Base.push!(terminals, Literal(true, nothing, nothing))
    elseif state == :false
        Base.push!(terminals, Literal(false, nothing, nothing))
    elseif state == :lang
        literal = last(terminals)
        literal.langtag = utf8(token)
    else
        # TODO invalid state
        error("invalid state in reduce!: " * string(state))
    end
    empty!(token)
end

function transition!(state::Array{Symbol})
    Base.pop!(state)
end

function transition!(state::Array{Symbol},
                     next::Symbol)
    Base.pop!(state)
    Base.push!(state, next)
end

function transition!(state::Array{Symbol},
                     next::Array{Symbol})
    Base.pop!(state)
    for next_state in next
        Base.push!(state, next_state)
    end
end

# Adding/removing statements

function push!(graph::Graph,
               subject::IRI,
               predicate::IRI,
               object::Union(Bool,Number,String))
    # Wrap up object as a Literal:
    push!(graph, subject, predicate, Literal(object))
end

function push!(graph::Graph,
               subject::IRI,
               predicate::IRI,
               object::Union(Literal,IRI))
    # Get dict mappings:
    subject_dict = get(graph.statements, string(subject), Dict{String,Set{Union(Literal,IRI)}}())
    predicate_set = get(subject_dict, string(predicate), Set{Union(Literal,IRI)}())

    # Add statement:
    objects_num = length(predicate_set)
    Base.push!(predicate_set, object)
    if objects_num != length(predicate_set)
        graph.size += 1
    end

    # Store newly created dicts/sets:
    if !haskey(subject_dict, object)
        subject_dict[string(predicate)] = predicate_set
    end
    if !haskey(graph.statements, subject)
        graph.statements[string(subject)] = subject_dict
    end
end

function pop!(graph::Graph,
              subject::IRI)
    # Get dict mappings;
    if !haskey(graph.statements, string(subject))
        return 0
    end
    subject_dict = Base.pop!(graph.statements, string(subject))

    # Remove statements:
    removed_statements = 0
    for predicate_objects = subject_dict
        removed_statements += length(predicate_objects[2])
    end
    graph.size -= removed_statements

    # Final number of removed statements:
    return removed_statements
end

function pop!(graph::Graph,
              subject::IRI,
              predicate::IRI)
    # Get dict mappings:
    if !haskey(graph.statements, string(subject))
        return 0
    end
    subject_dict = graph.statements[string(subject)]
    if !haskey(subject_dict, string(predicate))
        return 0
    end

    # Remove statements:
    objects = Base.pop!(subject_dict, string(predicate))
    removed_statements = length(objects)
    graph.size -= removed_statements

    # Remove empty dict:
    if length(subject_dict) == 0
        Base.pop!(graph.statements, string(subject))
    end

    # Final number of removed statements:
    return removed_statements
end

function pop!(graph::Graph,
              subject::IRI,
              predicate::IRI,
              object::Union(Literal,IRI))
    # Get dict mappings:
    if !haskey(graph.statements, string(subject))
        return 0
    end
    subject_dict = get(graph.statements, string(subject))
    if !haskey(subject_dict, string(predicate))
        return 0
    end
    predicate_set = get(subject_dict, string(predicate))

    # Remove statement:
    Base.pop!(predicate_set, object)
    graph.size -= 1

    # Remove empty dicts/sets:
    if length(predicate_set) == 0
        Base.pop!(subject_dict, string(predicate))
    end
    if length(subject_dict) == 0
        Base.pop!(graph.statements, string(subject))
    end

    # Final number of removed statements:
    return 1
end

### Extracting statements

function get_by_subject(graph::Graph,
                        subject::IRI)
    # Get dict mappings;
    if !haskey(graph.statements, string(subject))
        return 0
    end
    subject_dict = graph.statements[string(subject)]

    # Final number of removed statements:
    return removed_statements
end

### Iteration

function Base.start(graph::Graph)
    return RDF.GraphIterator(collect(keys(graph.statements)), [], [], [], [], [])
end

function Base.next(graph::Graph,
              state::GraphIterator)
    current_object = shift!(state.objects)
    return ((state.current_subject, state.current_predicate, current_object), state)
end

function Base.done(graph::Graph,
              state::GraphIterator)
    if length(state.subjects) == 0 && length(state.predicates) == 0 && length(state.objects) == 0
        return true
    end
    if length(state.predicates) == 0 && length(state.objects) == 0
        state.current_subject = shift!(state.subjects)
        state.predicates_under_subject = graph.statements[state.current_subject]
        state.predicates = collect(keys(state.predicates_under_subject))
    end
    if length(state.objects) == 0
        state.current_predicate = shift!(state.predicates)
        state.objects = collect(state.predicates_under_subject[state.current_predicate])
    end
    return false
end

### Serialization

function ntriples(graph::Graph,
                  out::Any)
    for statement = graph.statements
        for predicate_object = statement[2]
            for object = predicate_object[2]
                write(out, join(triple(statement[1], predicate_object[1], object)), " .\n")
            end
        end
    end
end

function nquads(graph::Graph,
                out::Any)
    for statement = graph.statements
        for predicate_object = statement[2]
            for object = predicate_object[2]
                write(out, join(triple(statement[1], predicate_object[1], object)), " <", string(graph.name), "> .\n")
            end
        end
    end
end

function turtle(graph::Graph,
                out::Any)
    subject_same = false
    predicate_same = false
    last_subject = nothing
    last_predicate = nothing
    last_object = nothing
    for statement = graph.statements
        for predicate_object = statement[2]
            for object = predicate_object[2]
                # Statement:
                subject = statement[1]
                predicate = predicate_object[1]

                # Serialize:
                prefix = ""
                if subject_same
                    prefix *= "    "
                elseif last_subject != nothing
                    prefix *= uri_rdf(last_subject) * " "
                end
                if predicate_same
                    prefix *= "    "
                elseif last_predicate != nothing
                    prefix *= uri_rdf(last_predicate) * " "
                end
                subject_same = last_subject == subject
                predicate_same = subject_same & (last_predicate == predicate)
                if subject_same
                    if predicate_same
                        write(out, prefix, object_rdf(last_object), " ,\n")
                    else
                        write(out, prefix, object_rdf(last_object), " ;\n")
                    end
                elseif last_subject != nothing
                    write(out, prefix, object_rdf(last_object), " .\n")
                end

                # Remember this statement, which only determined `separator`, but has not been serialized yet:
                last_subject = subject
                last_predicate = predicate
                last_object = object
            end
        end
    end

    # Serialize saved statement, if exists:
    if last_subject != nothing
        if subject_same
            if predicate_same
                write(out, "        ", object_rdf(last_object), " .\n")
            else
                write(out, "    ", uri_rdf(last_predicate), " ", object_rdf(last_object), " .\n")
            end
        else
            write(out, join(triple(last_subject, last_predicate, last_object)), " .\n")
        end
    end
end

function triple(subject::String,
                predicate::String,
                object::Union(Literal,IRI))
    return uri_rdf(subject), " ", uri_rdf(predicate), " ", object_rdf(object)
end

function uri_rdf(uri::String)
    # TODO Not complete yet; needs to handle IRI encoding/escaping.
    return string("<", uri, ">")
end

function object_rdf(literal::Literal)
    # TODO
    rdf = object_rdf(literal.value)
    # Give IRI precedence over language annotation, even though
    # both variables should not be set at the same time anyway.
    if literal.iri != nothing
        rdf *= "^^" * string(literal.iri)
    elseif literal.langtag != nothing
        rdf *= "@" * literal.langtag
    end
    return rdf
end

function object_rdf(value::String)
    # TODO I wonder whether there is a simpler way to do this...
    # TODO Also, this function is not complete yet.
    previous = nothing
    escaped_string = utf8("")
    for character = value
        if previous == nothing && character == '"'
            escaped_string *= "\\\""
        elseif character == '"' && previous != '"'
            escaped_string *= "\\\""
        else
            escaped_string *= string(character)
        end
        previous = character
    end
    return "\"" * escaped_string * "\""
end

function object_rdf(value::Number)
    # TODO Add RDF/RDFS type based on the particular number we're seeing.
    return string(value)
end

function object_rdf(value::Bool)
    return string(value)
end

function object_rdf(value::IRI)
    return uri_rdf(string(value))
end

end # module RDF

