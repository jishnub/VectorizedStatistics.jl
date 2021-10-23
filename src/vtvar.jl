"""
```julia
vtvar(A; dims=:, mean=nothing, corrected=true)
```
Compute the variance of all elements in `A`, optionally over dimensions specified by `dims`.
As `Statistics.var`, but vectorized and multithreaded.

A precomputed `mean` may optionally be provided, which results in a somewhat faster
calculation. If `corrected` is `true`, then _Bessel's correction_ is applied, such
that the sum is divided by `n-1` rather than `n`.

## Examples
```julia
julia> using VectorizedStatistics

julia> A = [1 2; 3 4]
2×2 Matrix{Int64}:
 1  2
 3  4

julia> vtvar(A, dims=1)
1×2 Matrix{Float64}:
 2.0  2.0

julia> vtvar(A, dims=2)
2×1 Matrix{Float64}:
 0.5
 0.5
```
"""
vtvar(A; dims=:, mean=nothing, corrected=true) = _vtvar(mean, corrected, A, dims)
export vtvar

# If dims is an integer, wrap it in a tuple
_vtvar(μ, corrected::Bool, A, dims::Int) = _vtvar(μ, corrected, A, (dims,))

# If the mean isn't known, compute it
_vtvar(::Nothing, corrected::Bool, A, dims::Tuple) = _vtvar!(_vtmean(A, dims), corrected, A, dims)
function _vtvar(::Nothing, corrected::Bool, A, ::Colon)
    # Reduce all the dims!
    n = length(A)
    Tₒ = Base.promote_op(/, eltype(A), Int)
    Σ = zero(Tₒ)
    @tturbo for i ∈ eachindex(A)
            Σ += A[i]
    end
    μ = Σ / n
    σ² = zero(typeof(μ))
    @tturbo for i ∈ eachindex(A)
            δ = A[i] - μ
            σ² += δ * δ
    end
    return σ² / (n-corrected)
end

# If the mean is known, pass it on in the appropriate form
_vtvar(μ, corrected::Bool, A, dims::Tuple) = _vtvar!(collect(μ), corrected, A, dims)
_vtvar(μ::Array, corrected::Bool, A, dims::Tuple) = _vtvar!(copy(μ), corrected, A, dims)
_vtvar(μ::Number, corrected::Bool, A, dims::Tuple) = _vtvar!([μ], corrected, A, dims)
function _vtvar(μ::Number, corrected::Bool, A, ::Colon)
    # Reduce all the dims!
    n = length(A)
    σ² = zero(typeof(μ))
    @tturbo for i ∈ eachindex(A)
        δ = A[i] - μ
        σ² += δ * δ
    end
    return σ² / (n-corrected)
end

# Chris Elrod metaprogramming magic:
# Generate customized set of loops for a given ndims and a vector
# `static_dims` of dimensions to reduce over
function staticdim_tvar_quote(static_dims::Vector{Int}, N::Int)
  M = length(static_dims)
  # `static_dims` now contains every dim we're taking the var over.
  Bᵥ = Expr(:call, :view, :B)
  reduct_inds = Int[]
  nonreduct_inds = Int[]
  # Firstly, build our expressions for indexing each array
  Aind = :(A[])
  Bind = :(Bᵥ[])
  inds = Vector{Symbol}(undef, N)
  len = Expr(:call, :*)
  for n ∈ 1:N
    ind = Symbol(:i_,n)
    inds[n] = ind
    push!(Aind.args, ind)
    if n ∈ static_dims
      push!(reduct_inds, n)
      push!(Bᵥ.args, :(firstindex(B,$n)))
      push!(len.args, :(size(A, $n)))
    else
      push!(nonreduct_inds, n)
      push!(Bᵥ.args, :)
      push!(Bind.args, ind)
    end
  end
  firstn = first(nonreduct_inds)
  # Secondly, build up our set of loops
  block = Expr(:block)
  loops = Expr(:for, :($(inds[firstn]) = indices((A,B),$firstn)), block)
  if length(nonreduct_inds) > 1
    for n ∈ @view(nonreduct_inds[2:end])
      newblock = Expr(:block)
      push!(block.args, Expr(:for, :($(inds[n]) = indices((A,B),$n)), newblock))
      block = newblock
    end
  end
  rblock = block
  # Push more things here if you want them at the beginning of the reduction loop
  push!(rblock.args, :(μ = $Bind))
  push!(rblock.args, :(σ² = zero(eltype(Bᵥ))))
  # Build the reduction loop
  for n ∈ reduct_inds
    newblock = Expr(:block)
    push!(block.args, Expr(:for, :($(inds[n]) = axes(A,$n)), newblock))
    block = newblock
  end
  # Push more things here if you want them in the innermost loop
  push!(block.args, :(δ = $Aind - μ))
  push!(block.args, :(σ² += δ * δ))
  # Push more things here if you want them at the end of the reduction loop
  push!(rblock.args, :($Bind = σ² * invdenom))
  # Put it all together
  quote
    invdenom = inv(($len) - corrected)
    Bᵥ = $Bᵥ
    @tturbo $loops
    return B
  end
end

# Chris Elrod metaprogramming magic:
# Turn non-static integers in `dims` tuple into `StaticInt`s
# so we can construct `static_dims` vector within @generated code
function branches_tvar_quote(N::Int, M::Int, D)
  static_dims = Int[]
  for m ∈ 1:M
    param = D.parameters[m]
    if param <: StaticInt
      new_dim = _dim(param)::Int
      @assert new_dim ∉ static_dims
      push!(static_dims, new_dim)
    else
      t = Expr(:tuple)
      for n ∈ static_dims
        push!(t.args, :(StaticInt{$n}()))
      end
      q = Expr(:block, :(dimm = dims[$m]))
      qold = q
      ifsym = :if
      for n ∈ 1:N
        n ∈ static_dims && continue
        tc = copy(t)
        push!(tc.args, :(StaticInt{$n}()))
        qnew = Expr(ifsym, :(dimm == $n), :(return _vtvar!(B, corrected, A, $tc)))
        for r ∈ m+1:M
          push!(tc.args, :(dims[$r]))
        end
        push!(qold.args, qnew)
        qold = qnew
        ifsym = :elseif
      end
      push!(qold.args, Expr(:block, :(throw("Dimension `$dimm` not found."))))
      return q
    end
  end
  staticdim_tvar_quote(static_dims, N)
end

# Efficient @generated in-place var
@generated function _vtvar!(B::AbstractArray{Tₒ,N}, corrected::Bool, A::AbstractArray{T,N}, dims::D) where {Tₒ,T,N,M,D<:Tuple{Vararg{Integer,M}}}
  N == M && return :(B[1] = _vtvar(B[1], corrected, A, :); B)
  branches_tvar_quote(N, M, D)
end
