"""
Plain-source entry point for the complete Julia IMDD transmitter.

This file intentionally does not define a module. Including it evaluates the
pattern generator, parameter definitions, and transmitter functions directly
in the caller's current module (normally `Main`), which makes individual
functions easy to inspect, call, and debug from the Julia REPL.

The include order is significant: transmitter functions depend on the pattern
functions and parameter structures, and the editable setup function validates
the completed parameter object before returning it.
"""

include(joinpath(@__DIR__, "IMDDPatterns.jl"))
include(joinpath(@__DIR__, "IMDDTransmitterConfig.jl"))
include(joinpath(@__DIR__, "IMDDTransmitter.jl"))
include(joinpath(@__DIR__, "IMDDTransmitterSetup.jl"))
