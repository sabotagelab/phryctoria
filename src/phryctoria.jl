module phryctoria

using Match
using DataStructures
using CSV

export startmonitor, process, foundroot!


"""
    process(comm::Channel, i, n)

A process which receives signal data, and as it finds roots sends them to the abstractor.
"""
function process(comm::Channel, i, n, ϵ) # Task
    filename = normpath("signals/signal" * string(i) * ".txt")
    data = []
    # While a signal exists
    for row ∈ CSV.Rows(filename; delim=',', types=Float64)
        # Assume piecewise linear for now
        t₂, x₂ = row.t, row.x
        push!(data, (t₂, x₂))
        if length(data) ≤ 1
            continue
        end
        (t₁, x₁) = data[end-1]
        # Go through signal until root
        if sign(x₁) ≠ sign(x₂)
            types = begin
                results = []
                if x₁ < 0
                    push!(results, leftroot)
                end
                if x₂ < 0
                    push!(results, rightroot)
                end
                results
            end
            loc = (t₁ * x₂ - t₂ * x₁) / (x₂ - x₁) # Root location considering a straight line between the two points
            id = string(i, "|", i, "|", loc)
            # Start with a default vector clock based on our current time
            V = zeros(n)
            V[i] = loc
            root = Root(id, i, types, loc, V)
            put!(comm, Comm(:foundroot, root, nothing))
        end
    end
end

"""
    combine(e₁, e₂)

Combine two events occurring on the same process at the same time to just one event.
"""
function combine(e₁, e₂)
    @match (e₁, e₂) begin
        (Root(id₁, pid, types, t, V₁), Event(_, pid, t, _, V₂)) ||
            (Event(_, pid, t, _, V₂), Root(id₁, pid, types, t, V₁)) => Root(id₁, pid, types, t, max.(V₁, V₂))
        (Event(id₁, pid, t, is_pos, V₁), Event(_, pid, t, is_pos, V₂)) => Event(id₁, pid, t, is_pos, max.(V₁, V₂))
        _ => error("Huh? How'd we end up with ", repr(e₁), " and ", repr(e₂), "?")
    end
end

"""
    updatelogV!(log, n)

Update vector clocks in the log.
"""
function updatelogV!(log, n)
    # Create a new vector clock of all zeros
    V = zeros(n)
    for e ∈ keys(log)
        e.V = max.(e.V, V)
        V = copy(e.V)
    end
end

"""
    updatelog!(log, event)

Add an event to the log, cleaning up duplicates.
"""
function updatelog!(log, event)
    for (e, t) ∈ log
        if t == event.t
            combined_event = combine(e, event)
            delete!(log, e)
            enqueue!(log, combined_event, combined_event.t)
            updatelogV!(log, length(event.V))
            return
        end
    end
    enqueue!(log, event, event.t)
    updatelogV!(log, length(event.V))
end

"""
    recentevent(log)

Get the most recent event from the log.
"""
function recentevent(log)
    # We need this function because PriorityQueue doesn't allow for retrieving the last element.
    # If we need more efficiency, consider using a SortedMultiDict (of DataStructures.jl) instead
    # of a PriorityQueue.
    # Hacky way to get the last element of the log
    last_event = nothing
    for e ∈ keys(log)
        last_event = e
    end
    last_event
end

"""
    foundroot!(comms, log, root)

Called whenever a root on the signal is found

trigger found a root:
"""
function foundroot!(comms, log, root)
    println("Root on process ", root.process, ": ", root.t)
    # Keep the root's vector clock consistent with the process's previous events
    begin
        for e ∈ keys(log)
            if e.t > root.t
                break
            end
            root.V = max.(root.V, e.V)
        end
    end
    # if root is right root:
    if rightroot ∈ root.types
        # for each process j ≠ i:
        for (j, comm) ∈ enumerate(comms)
            if j ≠ root.process
                # send root info to process j
                put!(comm, Comm(:remoteroot, root, nothing))
            end
        end
    end
    # add root info to log
    updatelog!(log, root)

    # Return type is used for determining positive intervals
    bound = if leftroot ∈ root.types && rightroot ∈ root.types
        :both
    elseif leftroot ∈ root.types
        :starting
    elseif rightroot ∈ root.types
        :ending
    else
        :neither
    end
    (bound, root.t)
end

"""
    locked(log)

Returns the index immediately before the last element of the log that we're sure won't move.

Assuming vector clocks are only set to show the → relation created by the abstractor. Before
sending to the solver, the abstractor must be sure to update vector clocks so the max
difference between any two elements is ϵ.
"""
function locked(log)
    # Vector clocks are currently set as they came in
    last_elem = recentevent(log).V

    # Go until there's partial overlap of the vector clocks
    for (j, e) ∈ enumerate(keys(log))
        # If all elements of e vector clock are less than those of last event in log
        if !all(isless.(e.V, last_elem))
            return j - 1
        end
    end
end

"""
    ispos(intervals, t)

TBW
"""
function ispos(intervals, t)
    for (a, b) ∈ intervals
        if ((isnothing(a) && t ≤ b)
            || (isnothing(b) && t ≥ a)
            || a ≤ t ≤ b)
            return true
        end
    end
    false
end

"""
    flushlog!(solver_comm, pos_intervals, log, flush_num)

TBW
"""
function flushlog!(solver_comm, pos_intervals, log, flush_num, ϵ)
    for _ = 1:flush_num
        # cut events from log and send to solver
        event = dequeue!(log)

        # Update vector clock to be consistent with ϵ
        event.V = max.(event.t - ϵ, event.V)

        println("Sending event ", repr(event.V), " to solver")
        put!(solver_comm, Comm(:newevent, event, pos_intervals))
    end
end

"""
    remoteroot!(solver_comm, pos_intervals, i, log, root, ϵ)

Called whenever receiving a communication about a remote right root

comms: Communication channels for all abstractor processes
solver: Communication channel for solver on the same process
pos_intervals: Positive intervals of the process
i: Process index
log: Log of the process
root: The received root

trigger received communiqué about right root from process j:
"""
function remoteroot!(solver_comm, pos_intervals, i, log, root, ϵ)
    # create new event e at time root.t + ϵ where root → e
    new_t = root.t + ϵ
    new_id = string(i, "|", root.process, "|", new_t)
    is_pos = ispos(pos_intervals, new_t)
    new_V = copy(root.V)
    new_V[i] = new_t
    new_event = Event(new_id, i, new_t, is_pos, new_V) # Event(id, process, t, ispos, V)
    # add e info to log
    updatelog!(log, new_event)
    # if there are any log events whose positions are locked in:
    flush_count = locked(log)
    flushlog!(solver_comm, pos_intervals, log, flush_count, ϵ)
end

"""
    updateintervals!(intervals, bound, t)

TBW
"""
function updateintervals!(intervals, bound, t)
    if isempty(intervals)
        if bound == :starting
            push!(intervals, (t, nothing))
        else
            push!(intervals, (nothing, t))
        end
        return
    end

    @match (bound, intervals[end]) begin
        (:starting, (_, b)), if !isnothing(b) end => push!(intervals, (t, nothing))
        (:ending, (a, nothing))                   => begin intervals[end] = (a, t) end
        (:both,     (_, b)), if !isnothing(b) end => push!(intervals, (t, t))
        (:neither, _)                             => nothing
        _ => error("Don't know how we got in this situation: (", bound, ", ", intervals[end], ")")
    end
end

"""
    abstractor!(comms, solver_comm, log, i, ϵ)

An abstractor which takes root data and discretizes it for the solver.
"""
function abstractor!(comms, solver_comm, log, i, ϵ) # Task
    pos_intervals = []
    while true
        data = take!(comms[i])
        @match data begin
            Comm(:foundroot, root, _) => begin
                (bound, t) = foundroot!(comms, log, root)
                # Keep track of positive intervals for SAT of new events
                updateintervals!(pos_intervals, bound, t)
            end
            Comm(:remoteroot, root, _) => remoteroot!(solver_comm, pos_intervals, i, log, root, ϵ)
        end
    end
end

"""
    cutcheck(falseprop, cut)

Checks the provided cut for existence of a conjunctive property.

    `falseprop` is a function which takes an index and event in the cut.
    If it returns true, the property is false (failed on that event).
"""
function cutcheck(falseprop, cut)
    for (i, event) ∈ enumerate(cut)
        if isnothing(event) || falseprop(i, event)
            return (false, i)
        end
    end
    true
end

"""
    isconsistentcut(cut, depend)

A cut is consistent iff ∀i: cut[i] ≥ depend[i].

If consistent, returns true. If inconsistent, returns a tuple of false and a process index which makes it inconsistent.
"""
isconsistentcut(cut, depend) = cutcheck((i, e) -> depend[i] > e.t, cut)

"""
    issatcut(cut)

If the cut satisfies the conjunctive predicate.

If satisfies, returns true. If doesn't satisfy, returns a tuple of false and a forbidden process index.
"""
issatcut(cut) = cutcheck((_, e) -> e isa Event && !e.ispos, cut)

"""
    addeventtotoken!(token, e)

TBW
"""
function addeventtotoken!(token, e)
    token.cut[e.process] = e
    token.depend = max.(token.depend, e.V)
end

"""
    sendtoken!(comm, waiting_tokens, token, predeval)

TBW
"""
function sendtoken!(comm, waiting_tokens, token, predeval)
    token_position = findfirst(x -> x.process == token.process, waiting_tokens)
    deleteat!(waiting_tokens, token_position)
    put!(comm, Comm(:token, token, predeval))
end

"""
    evaluatetoken!(comms, waiting_tokens, token)

TBW
"""
function evaluatetoken!(comms, waiting_tokens, token)
    @match issatcut(token.cut) begin
        true => sendtoken!(comms[token.process], waiting_tokens, token, true) # Found a satisfying cut! Send the token home
        (false, forbidprocess) => begin # Not a satisfying cut
            token.target = (forbidprocess, :after, token.cut[forbidprocess].t)
            sendtoken!(comms[forbidprocess], waiting_tokens, token, false)
        end
        _ => error("issatcut() API not what we're expecting!")
    end
end

"""
    processtoken!(comms, waiting_tokens, token)

TBW
"""
function processtoken!(comms, waiting_tokens, token)
    @match isconsistentcut(token.cut, token.depend) begin
        true => evaluatetoken!(comms, waiting_tokens, token) # We have a consistent cut
        (false, newprocess) => begin
            # Not a consistent cut
            token.target = if isnothing(token.cut[newprocess])
                (newprocess, :at, token.depend[newprocess])
            else
                (newprocess, :after, token.cut[newprocess].t)
            end
            sendtoken!(comms[newprocess], waiting_tokens, token, false)
        end
        _ => error("isconsistentcut() API not what we're expecting!")
    end
end

"""
    receiveevent!(events, comms, pos_intervals, waiting_tokens, e, ϵ)

TBW
"""
function receiveevent!(events, comms, pos_intervals, waiting_tokens, e, ϵ)
    # save e in events
    push!(events, e)

    # Should be up to date, just might need to create a virtual event
    for token ∈ copy(waiting_tokens)
        @match token.target begin
            (e.process, :at, e.t) => begin # Process the event for the token
                addeventtotoken!(token, e)
                processtoken!(comms, waiting_tokens, token)
            end
            (e.process, :after, t), if t < e.t end => begin # Process the event for the token
                addeventtotoken!(token, e)
                processtoken!(comms, waiting_tokens, token)
            end
            (e.process, :at, t), if t < e.t end => begin # Time for a virtual event
                n = length(token.cut)
                event = addvirtevent!(events, pos_intervals, n, e.process, t, ϵ)
                addeventtotoken!(token, event)
                processtoken!(comms, waiting_tokens, token)
            end
            (e.process, :at, _) => continue # Don't do anything, our target hasn't shown up yet
            _ => error("Something in the token's target isn't looking right: ", token.target)
        end
    end
end

"""
    addvirtevent!(events, pos_intervals, i, t, ϵ)

TBW
"""
function addvirtevent!(events, pos_intervals, n, i, t, ϵ)
    eventᵢ = searchsortedfirst(map(x -> x.t, events), t)
    new_id = string(i, "|", i, "|", t)
    is_pos = ispos(pos_intervals, t)
    new_V = fill(max(t - ϵ, 0.), n)
    new_V[i] = t
    new_event = Event(new_id, i, t, is_pos, new_V)
    insert!(events, eventᵢ, new_event)
    new_event
end

"""
    receivetoken!(events, comms, pos_intervals, waiting_tokens, token, i, ϵ, predtrue)

TBW
"""
function receivetoken!(events, comms, pos_intervals, waiting_tokens, token, i, ϵ, predtrue)
    push!(waiting_tokens, token)
    if predtrue && token.process == i
        sat_cut = max.(map(c -> c.V, token.cut)...)
        println("Found a satisfying cut! Token ", repr(token.process), ", cut ", repr(sat_cut))
        token.target = (i, :after, token.cut[i].t)
    end

    index = searchsortedfirst(map(x -> x.t, events), token.target[3])
    if index > length(events)
        return
        if token.target[2] === :at
            # We're up to date, now we just need to wait for a new event
            return
        else # Target is :after
            # There's an event which we've seen but didn't add to events
            error("Why didn't this event get added to events? ", token.target[3])
        end
    end
    @match token.target begin # Careful, the order of these arms matter
        (i, :after, events[end].t) => return # We're up to date, now we just need to wait for a new event
        (i, :after, events[index].t) => begin # Found the event at events[index + 1], process it
            addeventtotoken!(token, events[index + 1])
            processtoken!(comms, waiting_tokens, token)
        end
        (i, :after, _) || (i, :at, events[index].t) => begin # Found the event at events[index], process it
            addeventtotoken!(token, events[index])
            processtoken!(comms, waiting_tokens, token)
        end
        (i, :at, t) => begin # Didn't find it, need to create a virtual event
            n = length(token.cut)
            event = addvirtevent!(events, pos_intervals, n, i, t, ϵ)
            addeventtotoken!(token, event)
            processtoken!(comms, waiting_tokens, token)
        end
        _ => error("Something in the token's target isn't looking right: ", token.target)
    end
end

"""
    solver(comms, i, n, ϵ)

TBW
"""
function solver(comms, i, n, ϵ) # Task
    # Init token
    token = Token(i, [nothing for _ = 1:n], [0. for _ = 1:n], (i, :after, -1))
    events = []
    waiting_tokens = [token]
    pos_intervals = []
    while true
        data = take!(comms[i])
        @match data begin
            Comm(:newevent, e, pos_intervs) => begin
                # Need to stay up to date with positive intervals in case we need to build any virtual events
                pos_intervals = pos_intervs
                receiveevent!(events, comms, pos_intervals, waiting_tokens, e, ϵ)
            end
            Comm(:token, token, predtrue) => receivetoken!(events, comms, pos_intervals, waiting_tokens, token, i, ϵ, predtrue)
        end
    end
end

mutable struct Event
    id
    process
    t
    ispos
    V # Physical Vector Clock
end

mutable struct Root
    id
    process
    types
    t
    V
end

@enum RootType begin
    leftroot
    rightroot
end

struct Comm
    type::Symbol
    data
    info
end

mutable struct Token
    process
    cut::Vector{Union{Root,Event,Nothing}}
    depend
    target # (process, :at/:after, t)
end

"""
    startmonitor(n, ϵ)

TBW
"""
function startmonitor(n, ϵ)
    # Comms for the abstractor
    commsₐ = [Channel{Comm}(Inf) for _ = 1:n]
    logs = [PriorityQueue() for _ = 1:n]

    # Comms for the solver
    commsₛ = [Channel{Comm}(Inf) for _ = 1:n]

    for i in 1:n
        errormonitor(@async process(commsₐ[i], i, n, ϵ))
        errormonitor(@async abstractor!(commsₐ, commsₛ[i], logs[i], i, ϵ))
        errormonitor(@async solver(commsₛ, i, n, ϵ))
    end

    # Every agent async:
    #     get signal
    #     if signal root: send to abstractor
    #     Abstractor:
    #         check for root, comm from other agent
end

end # module
