module Rebugger

using REPL
using REPL.LineEdit
using Revise
using Revise: get_signature, signature_names, funcdef_body, get_def

# Organization:

## Code modification
## - methods: capture var values and names on entry to a specified slot, optionally throw error. Execute, then restore the original method.
## - capture vars at buffer position, call @which, throw error. (Here there is no method to repair.)

## Populate REPL with let block of method source

## REPL commands:
## F11 (^[[23~): step into expr at point   # Note: on konsole, F11 means fullscreen. Turn off in Settings->Configure Shortcuts
## Shift-F11 (^[[23;2~): step out
## Ctrl-F11 (^[[23;5~): step down stacktrace (avoids the need to place point)
## F5 (^[[15~): reinsert the last rebugger command. This allows extension of the stack.
## F9 (^[[20~): capture a stacktrace and start at the bottom
## "\em" (meta-m): create REPL line that populates Main with arguments to current method
## "\eS" (meta-S): save version at REPL to file? (a little dangerous, perhaps make it configurable as to whether this is on)

## Old:
## F11: step into expr at point (^[[23~)  # Note: on konsole, F11 means fullscreen. Turn off in Settings->Configure Shortcuts
## Shift-F11: step out (^[[23;2~)
## Ctrl-F11: step down stacktrace (avoids the need to place point) (^[[23;5~)
## F5: run command (not a point, from anywhere on REPL input line), collect stacktrace, and enter at end of trace (^[[15~)
## Shift-F5: clear the rebug stack? (^[[15;2~)  It's not obvious we need this; F5 should clear any existing stack & error stack.
## "\em" (meta-m): populate Main with arguments to current method
## X "\es" (meta-s): show current "stacktrace" (perhaps better, do this every time we navigate up or down. This might need separate modes depending on whether we are rebugging an error.)
## "\eS" (meta-S): save version at REPL to file? (a little dangerous, perhaps make it configurable as to whether this is on)

## Logic:
## - Maintain a stack of locations (Methods), varnames, and varvals. This makes step into & step out straightforward.
## - For entering at the end of the trace, do we have to capture all prior states? inlined methods could make this tricky.
##   consequently we might need an "unknown" status for varnames and varvals.
##   Once you've captured the stacktrace, it seems that one could rewrite each method to save its
##   variables (once? or better every time?) to a specific slot in the list.
## - Could be a little tricky handling both a pure stack (pure stepping) and a list-based approach (debugging an error).
##   We need storage of "the error stack" separate from "current stack". In the display of the stacktrace, distinguish
##   things that intersect with the error stack

## Interface/usability questions:
## - What happens if user just hits enter on a REPL line? That should not clear the stack.
## - Hitting the up-arrow should repeat the line. Should step-into insert in the history even if
##   it wasn't executed? (I think yes.)
## - Suppose a user starts stepping, then clears the input line, writes some more code, and
##   steps into something else. How to detect that this should extend the stack rather than
##   reset it? What if you go back manually (via REPL history) to an earlier entry?
##   Perhaps we should block these from the history and require that the user retrieves them
##   manually.

## OK, so a plain F11 resets the stack. However, it also sets a flag called `stepping`. If
## stepping is true the stack gets extended by the next F11.
## Hitting enter on the REPL sets `stepping` false (do this from the repl backend). F5 sets it to true again.

const VarnameType = Tuple{Vararg{Symbol}}
const stack       = Tuple{Method,VarnameType,Any}[]
const error_stack = Tuple{Method,VarnameType,Any}[]
const record      = Ref{Any}(nothing)

const stepping = Ref(false)

struct StopException <: Exception end
struct KeywordArg
    kwname::Symbol
    val
end
function KeywordArg(ex::Expr)
    @assert ex.head == :kw
    KeywordArg(ex.args[1], ex.args[2])
end

function capture_stacktrace(mod::Module, command::Expr)
    local trace
    errored = true
    try
        eval_noinfo(mod, command)
        errored = false
    catch
        trace = stacktrace(catch_backtrace())
    end
    errored || error("$command did not throw an error")
    # Truncate the stacktrace at eval_noinfo & check whether the same method appears in multiple slots
    calledmethods = Method[]
    for (i, t) in enumerate(trace)
        if t.func == :eval_noinfo
            resize!(trace, i-1)
            break
        end
        t.func ∈ notrace && continue
        startswith(String(t.func), '#') && continue # skip generated methods
        if !has_no_linfo(t)
            m = t.linfo.def
            @assert m isa Method
            push!(calledmethods, m)
        end
    end
    Base.show_backtrace(stderr, trace)
    print(stderr, '\n')
    length(unique(calledmethods)) == length(calledmethods) || @error "the same method appeared twice, not supported. Try stepping into the command."
    capture_stacktrace!(calledmethods) do
        eval_noinfo(mod, command)
    end
    # # Set up stack and error_stack
    # populate_replinput(lastitemonstack)  # move this elsewhere
end
capture_stacktrace(command::Expr) = capture_stacktrace(Main, command)

function capture_stacktrace!(f::Function, calledmethods::Vector)
    if isempty(calledmethods)
        # We've finished modifying all the methods, time to run the command
        try
            f()
            @warn "traced method did not throw an error"
        catch
        end
        return
    end
    method = calledmethods[end]
    def = get_def(method)
    if def != nothing
        # Now modify `def` to insert into slot `length(calledmethods)` (don't throw an error)
        # and eval it in the appropriate module
        reporting_method(method, def, length(calledmethods); trunc=false)
    end
    # Recurse up the stack until we get to the top...
    pop!(calledmethods)
    capture_stacktrace!(f, calledmethods)
    # ...after which it will call the erroring function and come back here.
    # Having come back, restore the original definition
    if def != nothing
        eval_noinfo(method.module, def)
    end
end

# function capture_and_err(method::Method, command)
#     def = get_def(method)
#     # Modify `def` to push! vars onto the end of stack and then throw a StopException
#     try
#         Core.eval(mod, command)
#     catch StopException
#     end
#     eval_noinfo(def)
# end

# This captures from the caller side
function insert_capture!(s)  # for testing, needs to work on a normal IO object
    start = position(s)
    str = LineEdit.content(s)
    expr, stop = Meta.parse(str, start; raise=false)
    (isa(expr, Expr) && expr.head == :call) || throw(Meta.ParseError("Point must be at a call expression, got $expr"))
    fname, args = expr.args[1], expr.args[2:end]
    if length(args) >= 1 && isa(args[1], Expr) && args[1].head == :parameters
        # This calls with keyword syntax, repackage
        for a in args[1].args
            push!(args, KeywordArg(a))
        end
        popfirst!(args)
    end
    captureexpr = quote
        Main.Rebugger.record[] = ($fname, ($(args...),))
        throw(StopException())
    end
    capturestr = replace(string(captureexpr), "KeywordArg"=>"Main.Rebugger.KeywordArg")
    capturestr = replace(capturestr, "StopException"=>"Main.Rebugger.StopException")
    LineEdit.edit_splice!(s, start=>stop-1, capturestr*"\n")
    return s
end

# Clever but probably useless stuff
# methsym = gensym("whichmethod")
# qexpr = QuoteNode(expr)
# stepexpr = quote
#     $methsym = Main.InteractiveUtils.@which($expr)
#     Main.Rebugger.varnames[] = Main.Rebugger.capture($methsym, $qexpr; on_err=false, params=true)
#     error("stop")
# end
# methstr = string(methsym)
# LineEdit.edit_splice!(s, start=>stop-1, replace(string(stepexpr), string(methsym)=>"\$(Symbol(\"$(methstr)\"))")*'\n')

function stepin(s)
    insert_capture!(s)
    # Now capture arg
    try
        Core.eval(Main, stufffroms)  # this should already start with an @eval mod ...
    catch StopException
    end
    empty!(s)
    f, args = record[]
    method = which(f, Base.typesof(args))
    def = get_def(method)
    # Now modify `def` to push! onto stack and throw a StopException
    # and eval it in the appropriate module
    try
        f(args...)
    catch StopException
    end
    eval_noinfo(def)
    populate_replinput(lastitemonstack)
end

function reporting_method(method, def, index; trunc::Bool=false)
    sigr, body = get_signature(def), unquote(funcdef_body(def))
    if sigr == nothing
        @warn "skipping capture: could not extract signature from $def"
        return nothing
    end
    sig = convert(Expr, sigr)
    methname, argnames, kwnames, paramnames = signature_names(sig)
    kwrepro = [:($name=$name) for name in kwnames]
    allnames = (argnames..., kwnames..., paramnames...)
    qallnames = QuoteNode.(allnames)
    stashexpr = :(Main.Rebugger.stack[$index] = ($method, ($(qallnames...),), Main.Rebugger.safe_deepcopy($(allnames...))))
    capture_body = trunc ? quote
        $stashexpr
        throw(Main.Rebugger.StopException())
    end : quote
        $stashexpr
        $body
    end
    capture_function = Expr(:function, sig, capture_body)
    if index > length(stack)
        resize!(stack, index)
    end
    mod = method.module
    Core.eval(mod, capture_function)
end

safe_deepcopy(a, args...) = (_deepcopy(a), safe_deepcopy(args...)...)
safe_deepcopy() = ()

_deepcopy(a) = deepcopy(a)
_deepcopy(a::Module) = a

has_no_linfo(sf::Base.StackFrame) = !isa(sf.linfo, Core.MethodInstance)


# Use to re-evaluate an expression without leaving "breadcrumbs" about where
# the eval is coming from. This is used below to prevent the re-evaluaton of an
# original method from being attributed to Revise itself in future backtraces.
eval_noinfo(mod::Module, ex::Expr) = ccall(:jl_toplevel_eval, Any, (Any, Any), mod, ex)
eval_noinfo(mod::Module, rex::Revise.RelocatableExpr) = eval_noinfo(mod, convert(Expr, rex))

function unquote(ex::Expr)
    if ex.head == :quote
        return Expr(:block, ex.args...)
    end
    ex
end
unquote(rex::Revise.RelocatableExpr) = unquote(convert(Expr, rex))

const notrace = (:error, :throw)

end # module
