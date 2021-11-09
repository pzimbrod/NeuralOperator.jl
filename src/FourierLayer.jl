"""
FourierLayer(in, out, batch, grid, modes, σ=identity, init=glorot_uniform)
FourierLayer(Wf::AbstractArray, Wl::AbstractArray, [bias_f, bias_l, σ])

Create a Layer of the Fourier Neural Operator as proposed by Zongyi et al.
arXiv: 2010.08895

The layer does a fourier transform on the last axis (the coeffs) of the input array,
filters higher modes out by the weight matrix and transforms the second axis to the
specified output dimension such that In x M x N -> Out x M x N.
The output though only contains the relevant Fourier modes with the rest padded to zero
in the last axis as a result of the filtering.

The input `x` should be a 3D tensor of shape
(num parameters (`in`) x num grid points (`grid`) x batch size (`batch`))
The output `y` will be a 3D tensor of shape
(`out` x num grid points (`grid`) x batch size (`batch`))

You can specify biases for the paths as you like, though the convolutional path is
originally not intended to perform an affine transformation.

# Examples
Say you're considering a 1D diffusion problem on a 64 point grid. The input is comprised
of the grid points as well as the IC at this point.
The data consists of 200 instances of the solution.
So the input takes the dimension `2 x 64 x 200`.
The output would be the diffused variable at a later time, which makes the output of the form
`2 x 200 x 64` as well.
"""
struct FourierLayer{F,Tc<:Complex{<:AbstractFloat},Tr<:AbstractFloat,Bf,Bl}
    # F: Activation, Tc/Tr: Complex/Real eltype
    Wf::AbstractArray{Tc,3}
    Wl::AbstractArray{Tr,3}
    𝔉::AbstractArray{Tc,3}
    i𝔉::AbstractArray{Tr,3}
    linear::AbstractArray{Tr,3}
    σ::F
    λ::Int
    bf::Bf
    bl::Bl
    # Constructor for the entire fourier layer
    function FourierLayer(
        Wf::AbstractArray{Tc,3}, Wl::AbstractArray{Tr,3}, 𝔉::AbstractArray{Tc,3}, 
        i𝔉::AbstractArray{Tr,3}, linear::AbstractArray{Tr,3}, σ::F = identity,
        λ::Int = 12, bf = true, bl = true) where
        {F,Tc<:Complex{<:AbstractFloat},Tr<:AbstractFloat}

        # create the biases with one singleton dimension
        bf = Flux.create_bias(Wf, bf, size(Wf,2), 1, size(Wf,3))
        bl = Flux.create_bias(Wl, bl, size(Wl,1), size(Wf,3), 1)
        new{F,Tc,Tr,typeof(bf),typeof(bl)}(Wf, Wl, 𝔉, i𝔉, linear, σ, λ, bf, bl)
    end
end

# Declare the function that assigns Weights and biases to the layer
# `in` and `out` refer to the dimensionality of the number of parameters
# `modes` specifies the number of modes not to be filtered out
# `grid` specifies the number of grid points in the data
function FourierLayer(in::Integer, out::Integer, batch::Integer, grid::Integer, modes = 12,
                        σ = identity; initf = cglorot_uniform, initl = Flux.glorot_uniform,
                        bias_fourier=true, bias_linear=true)

    # Initialize Fourier weight matrix (only with relevant modes)
    Wf = initf(in, out, modes)
    # Make sure filtering works
    @assert modes <= floor(Int, grid/2 + 1) "Specified modes exceed allowed maximum. 
    The number of modes to filter must be smaller than N/2 + 1"
    # Pad the fourier weight matrix with additional zeros
    Wf = pad_zeros(Wf, (0, floor(Int, grid/2 + 1) - modes), dims=3)

    # Initialize Linear weight matrix
    Wl = initl(out, in, 1)

    # Pass the bias bools
    bf = bias_fourier
    bl = bias_linear

    # Pass the modes for output
    λ = modes
    # Pre-allocate the interim arrays for the forward pass
    𝔉 = Array{ComplexF32}(undef, out, batch, floor(Int, grid/2 + 1))
    i𝔉 = Array{Float32}(undef, out, grid, batch)
    linear = similar(i𝔉)

    return FourierLayer(Wf, Wl, 𝔉, i𝔉, linear, σ, λ, bf, bl)
end

# Only train the weight array with non-zero modes
Flux.@functor FourierLayer 
Flux.trainable(a::FourierLayer) = (a.Wf[:,:,1:a.λ], a.Wl, 
                                typeof(a.bf) != Flux.Zeros ? a.bf[:,:,1:a.λ] : nothing,
                                typeof(a.bl) != Flux.Zeros ? a.bl : nothing)

# The actual layer that does stuff
function (a::FourierLayer)(x::AbstractArray)
    # Assign the parameters
    Wf, Wl, bf, bl, σ, = a.Wf, a.Wl, a.bf, a.bl, a.σ
    𝔉, i𝔉 = a.𝔉, a.i𝔉
    linear = a.linear

    # The linear path
    # x -> Wl
    linear .= batched_mul!(linear, Wl, x) .+ bl

    # The convolution path
    # x -> 𝔉 -> Wf -> i𝔉
    # Do the Fourier transform (FFT) along the grid dimension of the input and
    # Multiply the weight matrix with the input using batched multiplication
    # We need to permute the input, otherwise batching won't work
    𝔉 .= batched_mul!(𝔉, Wf, rfft(permutedims(x, [1,3,2]),3)) .+ bf

    # Do the inverse transform
    # We need to permute back to match the shape of the linear path
    i𝔉 = irfft(permutedims(𝔉, [1,3,2]), size(x,2), 2)

    # Return the activated sum
    return σ.(linear + i𝔉)
end

# Overload function to deal with higher-dimensional input arrays
#(a::FourierLayer)(x::AbstractArray) = reshape(a(reshape(x, size(x, 1), :)), :, size(x)[2:end]...)

# Print nicely
function Base.show(io::IO, l::FourierLayer)
    print(io, "FourierLayer with\nConvolution path: (", size(l.Wf, 2), ", ",
            size(l.Wf, 1), ", ", size(l.Wf, 3))
    print(io, ")\n")
    print(io, "Linear path: (", size(l.Wl, 2), ", ", size(l.Wl, 1))
    print(io, ")\n")
    print(io, "Fourier modes: ", l.λ)
    print(io, "\n")
    l.σ == identity || print(io, "Activation: ", l.σ)
end