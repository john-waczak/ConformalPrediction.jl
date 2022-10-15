"A base type for Transductive Conformal Classifiers."
abstract type TransductiveConformalClassifier <: TransductiveConformalModel end

# Simple
"The `NaiveClassifier` is the simplest approach to Inductive Conformal Classification. Contrary to the [`NaiveClassifier`](@ref) it computes nonconformity scores using a designated trainibration dataset."
mutable struct NaiveClassifier{Model <: Supervised} <: TransductiveConformalClassifier
    model::Model
    fitresult::Any
    scores::Union{Nothing,AbstractArray}
end

function NaiveClassifier(model::Supervised, fitresult=nothing)
    return NaiveClassifier(model, fitresult, nothing)
end


function score(conf_model::NaiveClassifier, Xtrain, ytrain)
    ŷ = pdf.(MMI.predict(conf_model.model, conf_model.fitresult, Xtrain),ytrain)
    return @.(1.0 - ŷ)
end

function prediction_region(conf_model::NaiveClassifier, Xnew, q̂::Real)
    p̂ = MMI.predict(conf_model.model, conf_model.fitresult, Xnew)
    L = p̂.decoder.classes
    ŷnew = pdf(p̂, L)
    ŷnew = map(x -> collect(key => 1-val <= q̂::Real ? val : missing for (key,val) in zip(L,x)),eachrow(ŷnew))
    return ŷnew 
end