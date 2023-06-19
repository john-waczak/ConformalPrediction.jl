using ComputationalResources
using Flux
using MLJFlux
import MLJModelInterface as MMI
using ProgressMeter
using Random
using Tables

const default_builder = MLJFlux.MLP(hidden=(32, 32, 32,), σ=Flux.relu)

"The `ConformalNNClassifier` struct is a wrapper for a `ConformalModel` that can be used with MLJFlux.jl."
mutable struct ConformalNNClassifier{B,F,O,L} <: MLJFlux.MLJFluxProbabilistic
    builder::B
    finaliser::F
    optimiser::O   # mutable struct from Flux/src/optimise/optimisers.jl
    loss::L        # can be called as in `loss(yhat, y)`
    epochs::Int    # number of epochs
    batch_size::Int  # size of a batch
    lambda::Float64  # regularization strength
    alpha::Float64   # regularizaton mix (0 for all l2, 1 for all l1)
    rng::Union{AbstractRNG,Int64}
    optimiser_changes_trigger_retraining::Bool
    acceleration::AbstractResource  # eg, `CPU1()` or `CUDALibs()`
end

function ConformalNNClassifier(;
    builder::B=default_builder,
    finaliser::F=Flux.softmax,
    optimiser::O=Flux.Optimise.Adam(),
    loss::L=Flux.crossentropy,
    epochs::Int=100, batch_size::Int=100, lambda::Float64=0.0, alpha::Float64=0.0,
    rng::Union{AbstractRNG,Int64}=Random.GLOBAL_RNG,
    optimiser_changes_trigger_retraining::Bool=false,
    acceleration::AbstractResource=CPU1(),
) where {B,F,O,L}

    # Initialise the MLJFlux wrapper:
    mod = ConformalNNClassifier(
        builder, finaliser, optimiser, loss, epochs, batch_size, lambda, alpha, rng,
        optimiser_changes_trigger_retraining, acceleration,
    )

    return mod
end

# if `b` is a builder, then `b(model, rng, shape...)` is called to make a
# new chain, where `shape` is the return value of this method:
function MLJFlux.shape(model::ConformalNNClassifier, X, y)
    levels = MMI.classes(y[1])
    n_output = length(levels)
    n_input = Tables.schema(X).names |> length
    return (n_input, n_output)
end

# builds the end-to-end Flux chain needed, given the `model` and `shape`:
function MLJFlux.build(model::ConformalNNClassifier, rng, shape)

    # Chain:
    chain = Flux.Chain(MLJFlux.build(model.builder, rng, shape...), model.finaliser)
    
    return chain
end

# returns the model `fitresult` (see "Adding Models for General Use"
# section of the MLJ manual) which must always have the form `(chain,
# metadata)`, where `metadata` is anything extra needed by `predict`:
MLJFlux.fitresult(model::ConformalNNClassifier, chain, y) =
    (chain, MMI.classes(y[1]))

function MMI.predict(
    model::ConformalNNClassifier,
    fitresult,
    Xnew
)
    chain, levels = fitresult
    X = MLJFlux.reformat(Xnew)
    probs = vcat([chain(MLJFlux.tomat(X[:, i]))' for i in 1:size(X, 2)]...)
    return MMI.UnivariateFinite(levels, probs)
end

MMI.metadata_model(ConformalNNClassifier,
    input=Union{AbstractArray,MMI.Table(MMI.Continuous)},
    target=AbstractVector{<:MMI.Finite},
    path="MLJFlux.ConformalNNClassifier")

@doc raw"""
    MLJFlux.train!(model::ConformalNNClassifier, penalty, chain, optimiser, X, y)

Implements the conformal traning procedure for the `ConformalNNClassifier` type.
"""
function MLJFlux.train!(model::ConformalNNClassifier, penalty, chain, optimiser, X, y)

    # Setup:
    loss = model.loss
    n_batches = length(y)
    training_loss = zero(Float32)
    size_loss = zero(Float32)
    fitresult = (chain, nothing)

    # Training loop:
    for i in 1:n_batches
        parameters = Flux.params(chain)

        # Data Splitting:
        X_batch, y_batch = X[i], y[i]
        conf_model = ConformalPrediction.conformal_model(model, method=:simple_inductive, coverage=0.95)
        calibration, pred = partition(1:size(y_batch,2), conf_model.train_ratio, shuffle=true)
        Xcal = X_batch[:,calibration]
        ycal = y_batch[:,calibration]
        Xcal, ycal = MMI.reformat(conf_model.model, Xcal, ycal)
        Xpred = X_batch[:,pred]
        ypred = y_batch[:,pred]
        Xpred, ypred = MMI.reformat(conf_model.model, Xpred, ypred)

        # On-the-fly calibration:
        cal_scores, scores = ConformalPrediction.score(conf_model, fitresult, Xcal', categorical(Flux.onecold(ycal)))
        conf_model.scores = Dict(
            :calibration => cal_scores,
            :all => scores,
        )

        gs = Flux.gradient(parameters) do
            Ω = smooth_size_loss(conf_model, fitresult, Xpred')
            yhat = chain(X_batch)
            batch_loss = loss(yhat, y_batch) + penalty(parameters) / n_batches 
            batch_loss += sum(Ω) / length(Ω)                            # add size loss
            training_loss += batch_loss
            size_loss += sum(Ω) / length(Ω)
            return batch_loss
        end
        Flux.update!(optimiser, parameters, gs)
    end

    return training_loss / n_batches
end
    

