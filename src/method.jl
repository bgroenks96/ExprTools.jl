"""
    signature(m::Method) -> Dict{Symbol,Any}

Finds the expression for a method's signature as broken up into its various components
including:

- `:name`: Name of the function
- `:params`: Parametric types defined on constructors
- `:args`: Positional arguments of the function
- `:whereparams`: Where parameters

All components listed above may not be present in the returned dictionary if they are
not in the function definition.

Limited support for:
- `:kwargs`: Keyword arguments of the function.
  Only the names will be included, not the default values or type constraints.

Unsupported:
- `:rtype`: Return type of the function
- `:body`: Function body0
- `:head`: Expression head of the function definition (`:function`, `:(=)`, `:(->)`)

For more complete coverage, consider using [`splitdef`](@ref)
with [`CodeTracking.definition`](https://github.com/timholy/CodeTracking.jl).

The dictionary of components returned by `signature` match those returned by
[`splitdef`](@ref) and include all that are required by [`combinedef`](@ref), except for
the `:body` component.
"""
function signature(m::Method)
    explicit_tvars = ExprTools.extract_tvars(m)

    def = Dict{Symbol, Any}()
    def[:name] = m.name

    def[:args] = arguments(m, explicit_tvars)
    def[:whereparams] = where_parameters(m)
    def[:params] = type_parameters(m)
    def[:kwargs] = kwargs(m)

    return Dict(k => v for (k, v) in def if v !== nothing)  # filter out nonfields.
end

function slot_names(m::Method)
    ci = Base.uncompressed_ast(m)
    return ci.slotnames
end

function argument_names(m::Method)
    slot_syms = slot_names(m)
    @assert slot_syms[1] === Symbol("#self#")
    arg_names = slot_syms[2:m.nargs]  # nargs includes 1 for `#self#`
    return arg_names
end

argument_types(m::Method) = argument_types(m.sig)
function argument_types(sig)
    # First parameter of `sig` is the type of the function itself
    return parameters(sig)[2:end]
end

module DummyThatHasOnlyDefaultImports end  # for working out visability

function name_of_module(m::Module)
    if Base.is_root_module(m)
        return nameof(m)
    else
        return :($(name_of_module(parentmodule(m))).$(nameof(m)))
    end
end
function name_of_type(x::Core.TypeName, _)
    #TODO: could let user pass this in, then we could be using what is inscope for them
    # but this is not important as we will give a correct (if overly verbose) output as is.
    from = DummyThatHasOnlyDefaultImports
    if Base.isvisible(x.name, x.module, from)  # avoid qualifying things that are in scope
        return x.name
    else
        return :($(name_of_module(x.module)).$(x.name))
    end
end

name_of_type(x::Symbol, _) = x  # Literal
function name_of_type(x::T, _) where T  # Literal
    # it is a bug in our implementation if this error every gets hit.
    isbits(x) || throw(DomainError((x, T), "not a valid type-param"))
    return x
end
name_of_type(tv::TypeVar, _) = tv.name
function name_of_type(x::DataType, explict_tvars=Core.TypeVar[])
    name = name_of_type(x.name, explict_tvars)
    # because tuples are varadic in number of type parameters having no parameters does not
    # mean you should not write the `{}`, so we special case them here.
    if isempty(x.parameters) && x != Tuple{}
        return name
    else
        parameter_names = map(t->name_of_type(t, explict_tvars), x.parameters)
        return :($(name){$(parameter_names...)})
    end
end


function name_of_type(x::UnionAll, explict_tvars=Core.TypeVar[])
    # we do nested union all unwrapping so we can make the more compact:
    # `foo{T,A} where {T, A}`` rather than the longer: `(foo{T,A} where T) where A`
    where_params = []
    while x isa UnionAll
        if x.var ∉ explict_tvars
            push!(where_params, where_parameter1(x.var))
        end
        x = x.body
    end

    name = name_of_type(x, explict_tvars)
    if isempty(where_params)
        return name
    else
        return :($name where {$(where_params...)})
    end
end

function name_of_type(x::Union, explict_tvars=Core.TypeVar[])
    parameter_names = map(t->name_of_type(t, explict_tvars), Base.uniontypes(x))
    return :(Union{$(parameter_names...)})
end

function arguments(m::Method, explicit_tvars=Core.TypeVar[])
    arg_names = argument_names(m)
    arg_types = argument_types(m)
    map(arg_names, arg_types) do name, type
        has_name = name !== Symbol("#unused#")
        type_name = name_of_type(type, explicit_tvars)
        if type === Any && has_name
            name
        elseif has_name
            :($name::$type_name)
        else
            :(::$type_name)
        end
    end
end

# type-vars can only show up attached to UnionAlls.
# so when showing name of type for bounds don't need to remove any `explicit_tvars`
function where_parameter1(x::TypeVar)
    if x.lb === Union{} && x.ub === Any
        return x.name
    elseif x.lb === Union{}
        return :($(x.name) <: $(name_of_type(x.ub)))
    elseif x.ub === Any
        return :($(x.name) >: $(name_of_type(x.lb)))
    else
        return :($(name_of_type(x.lb)) <: $(x.name) <: $(name_of_type(x.ub)))
    end
end

where_parameters(m::Method) = where_parameters(m.sig)
where_parameters(sig) = nothing
function where_parameters(sig::UnionAll)
    whereparams = []
    while sig isa UnionAll
        push!(whereparams, where_parameter1(sig.var))
        sig = sig.body
    end
    return whereparams
end

# type-space version of where_parameters
extract_tvars(m::Method) = extract_tvars(m.sig)
extract_tvars(sig) = Core.TypeVar[]
function extract_tvars(sig::UnionAll)
    tvars = Core.TypeVar[]
    while sig isa UnionAll
        push!(tvars, sig.var)
        sig = sig.body
    end
    return tvars
end


type_parameters(m::Method) = type_parameters(m.sig)
function type_parameters(sig)
    typeof_type = first(parameters(sig))  # will be e.g Type{Foo{P}} if it has any parameters
    typeof_type <: Type{<:Any} || return nothing

    function_type = first(parameters(typeof_type))  # will be e.g. Foo{P}
    parameter_types = parameters(function_type)
    return [name_of_type(type, Core.TypeVar[]) for type in parameter_types]
end

function kwargs(m::Method)
    names = kwarg_names(m)
    isempty(names) && return nothing  # we know it has no keywords.
    # TODO: Enhance this to support more than just their names
    # see https://github.com/invenia/ExprTools.jl/issues/6
    return names
end

function kwarg_names(m::Method)
    mt = Base.get_methodtable(m)
    !isdefined(mt, :kwsorter) && return []  # no kwsorter means no keywords for sure.
    return Base.kwarg_decl(m, typeof(mt.kwsorter))
end


#==
Hard case:
Base.ReshapedArray{T,N,A,Tuple} where A<:AbstractUnitRange where N where T

MWE:
ExprTools.name_of_type(Tuple{})
==#
