// WeftStdlib.swift - Standard library for WEFT language

import Foundation

/// Contains the WEFT standard library source code
/// These spindles are automatically prepended to user code
public enum WeftStdlib {

    /// The standard library source code
    public static let source = """
// WEFT Standard Library - Noise Functions

// ============================================================================
// Internal Helper Functions (prefixed with _ to indicate internal use)
// ============================================================================

// Hash function: maps 3D integer coordinates to pseudo-random value in [0,1]
spindle _hash31(px, py, pz) {
    return.0 = fract(sin(px * 127.1 + py * 311.7 + pz * 74.7) * 43758.5453)
}

// Hash to 3D gradient vector components
// Returns x component of gradient
spindle _hash3x(px, py, pz) {
    h.v = fract(sin(px * 127.1 + py * 269.5 + pz * 419.2) * 43758.5453)
    return.0 = h.v * 2 - 1
}

// Returns y component of gradient
spindle _hash3y(px, py, pz) {
    h.v = fract(sin(px * 269.5 + py * 183.3 + pz * 314.1) * 43758.5453)
    return.0 = h.v * 2 - 1
}

// Returns z component of gradient
spindle _hash3z(px, py, pz) {
    h.v = fract(sin(px * 419.2 + py * 371.9 + pz * 127.1) * 43758.5453)
    return.0 = h.v * 2 - 1
}

// Smoothstep fade curve for Perlin noise: 6t^5 - 15t^4 + 10t^3
spindle _fade(t) {
    return.0 = t * t * t * (t * (t * 6 - 15) + 10)
}

// Linear interpolation
spindle _lerp(a, b, t) {
    return.0 = a + t * (b - a)
}

// Gradient dot product for Perlin noise
// Computes dot(gradient(pi), p - pi) where pi is integer grid point
spindle _grad_dot(px, py, pz, fx, fy, fz) {
    gx.v = _hash3x(px, py, pz)
    gy.v = _hash3y(px, py, pz)
    gz.v = _hash3z(px, py, pz)
    return.0 = gx.v * fx + gy.v * fy + gz.v * fz
}

// ============================================================================
// Perlin Noise 3D
// ============================================================================

// 3D Perlin noise returning value in approximately [-1, 1]
// Usage: perlin3(x, y, z)
// For 2D: perlin3(x, y, 0)
// For animated 2D: perlin3(x * scale, y * scale, t * speed)
spindle perlin3(x, y, z) {
    // Integer grid coordinates
    ix.v = floor(x)
    iy.v = floor(y)
    iz.v = floor(z)

    // Fractional position within cell
    fx.v = x - ix.v
    fy.v = y - iy.v
    fz.v = z - iz.v

    // Fade curves for interpolation
    u.v = _fade(fx.v)
    v.v = _fade(fy.v)
    w.v = _fade(fz.v)

    // Gradient dot products at 8 corners of the cube
    // Corner (0,0,0)
    n000.v = _grad_dot(ix.v, iy.v, iz.v, fx.v, fy.v, fz.v)
    // Corner (1,0,0)
    n100.v = _grad_dot(ix.v + 1, iy.v, iz.v, fx.v - 1, fy.v, fz.v)
    // Corner (0,1,0)
    n010.v = _grad_dot(ix.v, iy.v + 1, iz.v, fx.v, fy.v - 1, fz.v)
    // Corner (1,1,0)
    n110.v = _grad_dot(ix.v + 1, iy.v + 1, iz.v, fx.v - 1, fy.v - 1, fz.v)
    // Corner (0,0,1)
    n001.v = _grad_dot(ix.v, iy.v, iz.v + 1, fx.v, fy.v, fz.v - 1)
    // Corner (1,0,1)
    n101.v = _grad_dot(ix.v + 1, iy.v, iz.v + 1, fx.v - 1, fy.v, fz.v - 1)
    // Corner (0,1,1)
    n011.v = _grad_dot(ix.v, iy.v + 1, iz.v + 1, fx.v, fy.v - 1, fz.v - 1)
    // Corner (1,1,1)
    n111.v = _grad_dot(ix.v + 1, iy.v + 1, iz.v + 1, fx.v - 1, fy.v - 1, fz.v - 1)

    // Trilinear interpolation
    nx00.v = _lerp(n000.v, n100.v, u.v)
    nx10.v = _lerp(n010.v, n110.v, u.v)
    nx01.v = _lerp(n001.v, n101.v, u.v)
    nx11.v = _lerp(n011.v, n111.v, u.v)

    nxy0.v = _lerp(nx00.v, nx10.v, v.v)
    nxy1.v = _lerp(nx01.v, nx11.v, v.v)

    return.0 = _lerp(nxy0.v, nxy1.v, w.v)
}

// ============================================================================
// Simplex Noise 3D
// ============================================================================

// 3D Simplex noise returning value in approximately [-1, 1]
// Faster than Perlin for higher dimensions, no visible grid artifacts
spindle simplex3(x, y, z) {
    // Skewing factors for 3D
    // F3 = 1/3, G3 = 1/6
    F3.v = 0.333333333
    G3.v = 0.166666667

    // Skew input space to determine simplex cell
    s.v = (x + y + z) * F3.v
    i.v = floor(x + s.v)
    j.v = floor(y + s.v)
    k.v = floor(z + s.v)

    // Unskew back to get first corner in (x,y,z) coords
    t.v = (i.v + j.v + k.v) * G3.v
    x0.v = x - (i.v - t.v)
    y0.v = y - (j.v - t.v)
    z0.v = z - (k.v - t.v)

    // Determine which simplex we're in by comparing x0, y0, z0
    // Using step functions to determine ordering
    xy.v = step(y0.v, x0.v)
    xz.v = step(z0.v, x0.v)
    yz.v = step(z0.v, y0.v)

    // Offsets for second corner (i1,j1,k1)
    i1.v = xy.v * xz.v
    j1.v = (1 - xy.v) * yz.v
    k1.v = (1 - xz.v) * (1 - yz.v)

    // Offsets for third corner (i2,j2,k2)
    i2.v = step(1 - i1.v, j1.v + k1.v)
    j2.v = step(1 - j1.v, i1.v + k1.v)
    k2.v = step(1 - k1.v, i1.v + j1.v)

    // Positions relative to other corners
    x1.v = x0.v - i1.v + G3.v
    y1.v = y0.v - j1.v + G3.v
    z1.v = z0.v - k1.v + G3.v

    x2.v = x0.v - i2.v + 2 * G3.v
    y2.v = y0.v - j2.v + 2 * G3.v
    z2.v = z0.v - k2.v + 2 * G3.v

    x3.v = x0.v - 1 + 3 * G3.v
    y3.v = y0.v - 1 + 3 * G3.v
    z3.v = z0.v - 1 + 3 * G3.v

    // Calculate contribution from four corners
    // Radial falloff: (0.6 - d^2)^4 where d^2 = x^2 + y^2 + z^2

    // Corner 0
    d0.v = 0.6 - x0.v * x0.v - y0.v * y0.v - z0.v * z0.v
    t0.v = max(0, d0.v)
    t0.v = t0.v * t0.v * t0.v * t0.v
    g0.v = _hash3x(i.v, j.v, k.v) * x0.v + _hash3y(i.v, j.v, k.v) * y0.v + _hash3z(i.v, j.v, k.v) * z0.v
    n0.v = t0.v * g0.v

    // Corner 1
    d1.v = 0.6 - x1.v * x1.v - y1.v * y1.v - z1.v * z1.v
    t1.v = max(0, d1.v)
    t1.v = t1.v * t1.v * t1.v * t1.v
    g1.v = _hash3x(i.v + i1.v, j.v + j1.v, k.v + k1.v) * x1.v + _hash3y(i.v + i1.v, j.v + j1.v, k.v + k1.v) * y1.v + _hash3z(i.v + i1.v, j.v + j1.v, k.v + k1.v) * z1.v
    n1.v = t1.v * g1.v

    // Corner 2
    d2.v = 0.6 - x2.v * x2.v - y2.v * y2.v - z2.v * z2.v
    t2.v = max(0, d2.v)
    t2.v = t2.v * t2.v * t2.v * t2.v
    g2.v = _hash3x(i.v + i2.v, j.v + j2.v, k.v + k2.v) * x2.v + _hash3y(i.v + i2.v, j.v + j2.v, k.v + k2.v) * y2.v + _hash3z(i.v + i2.v, j.v + j2.v, k.v + k2.v) * z2.v
    n2.v = t2.v * g2.v

    // Corner 3
    d3.v = 0.6 - x3.v * x3.v - y3.v * y3.v - z3.v * z3.v
    t3.v = max(0, d3.v)
    t3.v = t3.v * t3.v * t3.v * t3.v
    g3.v = _hash3x(i.v + 1, j.v + 1, k.v + 1) * x3.v + _hash3y(i.v + 1, j.v + 1, k.v + 1) * y3.v + _hash3z(i.v + 1, j.v + 1, k.v + 1) * z3.v
    n3.v = t3.v * g3.v

    // Scale to [-1, 1] range (32 is empirical scaling factor)
    return.0 = 32 * (n0.v + n1.v + n2.v + n3.v)
}

// ============================================================================
// Fractal Brownian Motion (fBm) - Harmonic Summation
// ============================================================================

// 8-octave fBm using Perlin noise
// spread: frequency multiplier per octave (typically 2)
// roughness: amplitude decay per octave (typically 0.5)
spindle fbm3(x, y, z, spread, roughness) {
    amp.v = 0.5
    freq.v = 1
    n.v = perlin3(x * freq.v, y * freq.v, z * freq.v) * amp.v

    freq.v = freq.v * spread
    amp.v = amp.v * roughness
    n.v = n.v + perlin3(x * freq.v, y * freq.v, z * freq.v) * amp.v

    freq.v = freq.v * spread
    amp.v = amp.v * roughness
    n.v = n.v + perlin3(x * freq.v, y * freq.v, z * freq.v) * amp.v

    freq.v = freq.v * spread
    amp.v = amp.v * roughness
    n.v = n.v + perlin3(x * freq.v, y * freq.v, z * freq.v) * amp.v

    freq.v = freq.v * spread
    amp.v = amp.v * roughness
    n.v = n.v + perlin3(x * freq.v, y * freq.v, z * freq.v) * amp.v

    freq.v = freq.v * spread
    amp.v = amp.v * roughness
    n.v = n.v + perlin3(x * freq.v, y * freq.v, z * freq.v) * amp.v

    freq.v = freq.v * spread
    amp.v = amp.v * roughness
    n.v = n.v + perlin3(x * freq.v, y * freq.v, z * freq.v) * amp.v

    freq.v = freq.v * spread
    amp.v = amp.v * roughness
    n.v = n.v + perlin3(x * freq.v, y * freq.v, z * freq.v) * amp.v

    return.0 = n.v
}

// ============================================================================
// Cell/Worley/Voronoi Noise
// ============================================================================

// Returns distance to nearest random feature point
// Creates organic cell/crack patterns
spindle cell3(x, y, z) {
    ix.v = floor(x)
    iy.v = floor(y)
    iz.v = floor(z)
    fx.v = x - ix.v
    fy.v = y - iy.v
    fz.v = z - iz.v

    // Initialize with large distance
    minDist.v = 10

    // Check 3x3x3 neighborhood (27 cells)
    // Cell (-1,-1,-1)
    px.v = _hash31(ix.v - 1, iy.v - 1, iz.v - 1)
    py.v = _hash31(ix.v - 1 + 0.1, iy.v - 1, iz.v - 1)
    pz.v = _hash31(ix.v - 1, iy.v - 1 + 0.1, iz.v - 1)
    dx.v = -1 + px.v - fx.v
    dy.v = -1 + py.v - fy.v
    dz.v = -1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (0,-1,-1)
    px.v = _hash31(ix.v, iy.v - 1, iz.v - 1)
    py.v = _hash31(ix.v + 0.1, iy.v - 1, iz.v - 1)
    pz.v = _hash31(ix.v, iy.v - 1 + 0.1, iz.v - 1)
    dx.v = 0 + px.v - fx.v
    dy.v = -1 + py.v - fy.v
    dz.v = -1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (1,-1,-1)
    px.v = _hash31(ix.v + 1, iy.v - 1, iz.v - 1)
    py.v = _hash31(ix.v + 1 + 0.1, iy.v - 1, iz.v - 1)
    pz.v = _hash31(ix.v + 1, iy.v - 1 + 0.1, iz.v - 1)
    dx.v = 1 + px.v - fx.v
    dy.v = -1 + py.v - fy.v
    dz.v = -1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (-1,0,-1)
    px.v = _hash31(ix.v - 1, iy.v, iz.v - 1)
    py.v = _hash31(ix.v - 1 + 0.1, iy.v, iz.v - 1)
    pz.v = _hash31(ix.v - 1, iy.v + 0.1, iz.v - 1)
    dx.v = -1 + px.v - fx.v
    dy.v = 0 + py.v - fy.v
    dz.v = -1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (0,0,-1)
    px.v = _hash31(ix.v, iy.v, iz.v - 1)
    py.v = _hash31(ix.v + 0.1, iy.v, iz.v - 1)
    pz.v = _hash31(ix.v, iy.v + 0.1, iz.v - 1)
    dx.v = 0 + px.v - fx.v
    dy.v = 0 + py.v - fy.v
    dz.v = -1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (1,0,-1)
    px.v = _hash31(ix.v + 1, iy.v, iz.v - 1)
    py.v = _hash31(ix.v + 1 + 0.1, iy.v, iz.v - 1)
    pz.v = _hash31(ix.v + 1, iy.v + 0.1, iz.v - 1)
    dx.v = 1 + px.v - fx.v
    dy.v = 0 + py.v - fy.v
    dz.v = -1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (-1,1,-1)
    px.v = _hash31(ix.v - 1, iy.v + 1, iz.v - 1)
    py.v = _hash31(ix.v - 1 + 0.1, iy.v + 1, iz.v - 1)
    pz.v = _hash31(ix.v - 1, iy.v + 1 + 0.1, iz.v - 1)
    dx.v = -1 + px.v - fx.v
    dy.v = 1 + py.v - fy.v
    dz.v = -1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (0,1,-1)
    px.v = _hash31(ix.v, iy.v + 1, iz.v - 1)
    py.v = _hash31(ix.v + 0.1, iy.v + 1, iz.v - 1)
    pz.v = _hash31(ix.v, iy.v + 1 + 0.1, iz.v - 1)
    dx.v = 0 + px.v - fx.v
    dy.v = 1 + py.v - fy.v
    dz.v = -1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (1,1,-1)
    px.v = _hash31(ix.v + 1, iy.v + 1, iz.v - 1)
    py.v = _hash31(ix.v + 1 + 0.1, iy.v + 1, iz.v - 1)
    pz.v = _hash31(ix.v + 1, iy.v + 1 + 0.1, iz.v - 1)
    dx.v = 1 + px.v - fx.v
    dy.v = 1 + py.v - fy.v
    dz.v = -1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (-1,-1,0)
    px.v = _hash31(ix.v - 1, iy.v - 1, iz.v)
    py.v = _hash31(ix.v - 1 + 0.1, iy.v - 1, iz.v)
    pz.v = _hash31(ix.v - 1, iy.v - 1 + 0.1, iz.v)
    dx.v = -1 + px.v - fx.v
    dy.v = -1 + py.v - fy.v
    dz.v = 0 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (0,-1,0)
    px.v = _hash31(ix.v, iy.v - 1, iz.v)
    py.v = _hash31(ix.v + 0.1, iy.v - 1, iz.v)
    pz.v = _hash31(ix.v, iy.v - 1 + 0.1, iz.v)
    dx.v = 0 + px.v - fx.v
    dy.v = -1 + py.v - fy.v
    dz.v = 0 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (1,-1,0)
    px.v = _hash31(ix.v + 1, iy.v - 1, iz.v)
    py.v = _hash31(ix.v + 1 + 0.1, iy.v - 1, iz.v)
    pz.v = _hash31(ix.v + 1, iy.v - 1 + 0.1, iz.v)
    dx.v = 1 + px.v - fx.v
    dy.v = -1 + py.v - fy.v
    dz.v = 0 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (-1,0,0)
    px.v = _hash31(ix.v - 1, iy.v, iz.v)
    py.v = _hash31(ix.v - 1 + 0.1, iy.v, iz.v)
    pz.v = _hash31(ix.v - 1, iy.v + 0.1, iz.v)
    dx.v = -1 + px.v - fx.v
    dy.v = 0 + py.v - fy.v
    dz.v = 0 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (0,0,0)
    px.v = _hash31(ix.v, iy.v, iz.v)
    py.v = _hash31(ix.v + 0.1, iy.v, iz.v)
    pz.v = _hash31(ix.v, iy.v + 0.1, iz.v)
    dx.v = 0 + px.v - fx.v
    dy.v = 0 + py.v - fy.v
    dz.v = 0 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (1,0,0)
    px.v = _hash31(ix.v + 1, iy.v, iz.v)
    py.v = _hash31(ix.v + 1 + 0.1, iy.v, iz.v)
    pz.v = _hash31(ix.v + 1, iy.v + 0.1, iz.v)
    dx.v = 1 + px.v - fx.v
    dy.v = 0 + py.v - fy.v
    dz.v = 0 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (-1,1,0)
    px.v = _hash31(ix.v - 1, iy.v + 1, iz.v)
    py.v = _hash31(ix.v - 1 + 0.1, iy.v + 1, iz.v)
    pz.v = _hash31(ix.v - 1, iy.v + 1 + 0.1, iz.v)
    dx.v = -1 + px.v - fx.v
    dy.v = 1 + py.v - fy.v
    dz.v = 0 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (0,1,0)
    px.v = _hash31(ix.v, iy.v + 1, iz.v)
    py.v = _hash31(ix.v + 0.1, iy.v + 1, iz.v)
    pz.v = _hash31(ix.v, iy.v + 1 + 0.1, iz.v)
    dx.v = 0 + px.v - fx.v
    dy.v = 1 + py.v - fy.v
    dz.v = 0 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (1,1,0)
    px.v = _hash31(ix.v + 1, iy.v + 1, iz.v)
    py.v = _hash31(ix.v + 1 + 0.1, iy.v + 1, iz.v)
    pz.v = _hash31(ix.v + 1, iy.v + 1 + 0.1, iz.v)
    dx.v = 1 + px.v - fx.v
    dy.v = 1 + py.v - fy.v
    dz.v = 0 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (-1,-1,1)
    px.v = _hash31(ix.v - 1, iy.v - 1, iz.v + 1)
    py.v = _hash31(ix.v - 1 + 0.1, iy.v - 1, iz.v + 1)
    pz.v = _hash31(ix.v - 1, iy.v - 1 + 0.1, iz.v + 1)
    dx.v = -1 + px.v - fx.v
    dy.v = -1 + py.v - fy.v
    dz.v = 1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (0,-1,1)
    px.v = _hash31(ix.v, iy.v - 1, iz.v + 1)
    py.v = _hash31(ix.v + 0.1, iy.v - 1, iz.v + 1)
    pz.v = _hash31(ix.v, iy.v - 1 + 0.1, iz.v + 1)
    dx.v = 0 + px.v - fx.v
    dy.v = -1 + py.v - fy.v
    dz.v = 1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (1,-1,1)
    px.v = _hash31(ix.v + 1, iy.v - 1, iz.v + 1)
    py.v = _hash31(ix.v + 1 + 0.1, iy.v - 1, iz.v + 1)
    pz.v = _hash31(ix.v + 1, iy.v - 1 + 0.1, iz.v + 1)
    dx.v = 1 + px.v - fx.v
    dy.v = -1 + py.v - fy.v
    dz.v = 1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (-1,0,1)
    px.v = _hash31(ix.v - 1, iy.v, iz.v + 1)
    py.v = _hash31(ix.v - 1 + 0.1, iy.v, iz.v + 1)
    pz.v = _hash31(ix.v - 1, iy.v + 0.1, iz.v + 1)
    dx.v = -1 + px.v - fx.v
    dy.v = 0 + py.v - fy.v
    dz.v = 1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (0,0,1)
    px.v = _hash31(ix.v, iy.v, iz.v + 1)
    py.v = _hash31(ix.v + 0.1, iy.v, iz.v + 1)
    pz.v = _hash31(ix.v, iy.v + 0.1, iz.v + 1)
    dx.v = 0 + px.v - fx.v
    dy.v = 0 + py.v - fy.v
    dz.v = 1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (1,0,1)
    px.v = _hash31(ix.v + 1, iy.v, iz.v + 1)
    py.v = _hash31(ix.v + 1 + 0.1, iy.v, iz.v + 1)
    pz.v = _hash31(ix.v + 1, iy.v + 0.1, iz.v + 1)
    dx.v = 1 + px.v - fx.v
    dy.v = 0 + py.v - fy.v
    dz.v = 1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (-1,1,1)
    px.v = _hash31(ix.v - 1, iy.v + 1, iz.v + 1)
    py.v = _hash31(ix.v - 1 + 0.1, iy.v + 1, iz.v + 1)
    pz.v = _hash31(ix.v - 1, iy.v + 1 + 0.1, iz.v + 1)
    dx.v = -1 + px.v - fx.v
    dy.v = 1 + py.v - fy.v
    dz.v = 1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (0,1,1)
    px.v = _hash31(ix.v, iy.v + 1, iz.v + 1)
    py.v = _hash31(ix.v + 0.1, iy.v + 1, iz.v + 1)
    pz.v = _hash31(ix.v, iy.v + 1 + 0.1, iz.v + 1)
    dx.v = 0 + px.v - fx.v
    dy.v = 1 + py.v - fy.v
    dz.v = 1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    // Cell (1,1,1)
    px.v = _hash31(ix.v + 1, iy.v + 1, iz.v + 1)
    py.v = _hash31(ix.v + 1 + 0.1, iy.v + 1, iz.v + 1)
    pz.v = _hash31(ix.v + 1, iy.v + 1 + 0.1, iz.v + 1)
    dx.v = 1 + px.v - fx.v
    dy.v = 1 + py.v - fy.v
    dz.v = 1 + pz.v - fz.v
    d.v = sqrt(dx.v*dx.v + dy.v*dy.v + dz.v*dz.v)
    minDist.v = min(minDist.v, d.v)

    return.0 = minDist.v
}
"""
}
