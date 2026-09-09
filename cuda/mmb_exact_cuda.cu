/*
 * mmb_exact_cuda.cu
 *
 * Exact discrete MMB computation by zonotope tiling.
 * Each GPU thread processes one tile, computes its cross-section with the
 * fixed first response, and maps candidate vertices to the second response.
 * The final convex hull is computed separately on the CPU.
 *
 * mmb_kernel is a template on the rank R of the six sensors, and a tile is
 * a set of R wavelengths. At rank 6 the generators are used as read. Below
 * 6 the host reorders the three channels of the second response so that
 * the first R rows of the generators span the space all six span.
 *
 * Use --chunk and --nchunks to divide the tile range between jobs.
 * The target architecture is set at build time; the Makefile defaults to
 * sm_90 (H100). The Makefile also passes --fmad=false, which disables
 * fused multiply-add contraction. The published results depend on it.
 *
 * Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <limits.h>
#include <float.h>
#include <cuda_runtime.h>

#define MAX_N       410
#define D           6
#define D_HALF      3
#define MAX_VERTS_DEFAULT 50000000
/* Sets of R - 3 of the 2R constraint planes: C(12,3) at rank 6, the most */
#define MAX_PLANE_SETS 220
#define MAX_VPTS    30

#define CUDA_CHECK(call) do { \
    cudaError_t err = call; \
    if (err != cudaSuccess) { \
        fprintf(stderr, "CUDA error at %s:%d: %s\n", \
                __FILE__, __LINE__, cudaGetErrorString(err)); \
        exit(EXIT_FAILURE); \
    } \
} while(0)

/* GPU constant memory */
__constant__ double d_G6[D * MAX_N];
__constant__ double d_h6[MAX_N];
__constant__ double d_z0[D_HALF];
__constant__ int d_n;
__constant__ int d_plane_sets[MAX_PLANE_SETS][3];
__constant__ long long d_max_verts;
/* Squared color-match tolerance, computed on the host from ||z0||. */
__constant__ double d_zmatch_tol;

/* Diagnostic counters */
__device__ unsigned long long d_rejected_physical;
__device__ unsigned long long d_rejected_zmatch;
__device__ unsigned long long d_rejected_nonfinite;
__device__ unsigned long long d_max_vpts_hits;

/* Device helpers */

__host__ __device__ void unrank_lex(long long k, int n, int d, int *basis) {
    long long remaining = k;
    int start = 0;
    for (int pos = 0; pos < d; pos++) {
        for (int val = start; val < n; val++) {
            int slots = d - pos - 1;
            int items = n - val - 1;
            if (items < slots) continue;
            long long count = 1;
            for (int j = 0; j < slots; j++)
                count = count * (items - j) / (j + 1);
            if (remaining < count) {
                basis[pos] = val;
                start = val + 1;
                break;
            }
            remaining -= count;
        }
    }
}

__host__ __device__ constexpr long long nchoosek(int n, int k) {
    long long c = 1;
    for (int i = 0; i < k; i++) c = c * (n - i) / (i + 1);
    return c;
}

template <int R>
__device__ int lu(double A[R][R], int piv[R]) {
    for (int i = 0; i < R; i++) piv[i] = i;
    for (int col = 0; col < R; col++) {
        double mx = fabs(A[col][col]); int mr = col;
        for (int r = col+1; r < R; r++) {
            double v = fabs(A[r][col]);
            if (v > mx) { mx = v; mr = r; }
        }
        if (mx < 1e-20) return -1;
        if (mr != col) {
            int t = piv[col]; piv[col] = piv[mr]; piv[mr] = t;
            for (int j = 0; j < R; j++) {
                double t2 = A[col][j]; A[col][j] = A[mr][j]; A[mr][j] = t2;
            }
        }
        for (int r = col+1; r < R; r++) {
            A[r][col] /= A[col][col];
            for (int j = col+1; j < R; j++)
                A[r][j] -= A[r][col] * A[col][j];
        }
    }
    return 0;
}

template <int R>
__device__ void lu_solve(double LU[R][R], int piv[R], const double *b, double *x) {
    double y[R];
    for (int i = 0; i < R; i++) {
        y[i] = b[piv[i]];
        for (int j = 0; j < i; j++) y[i] -= LU[i][j] * y[j];
    }
    for (int i = R-1; i >= 0; i--) {
        x[i] = y[i];
        for (int j = i+1; j < R; j++) x[i] -= LU[i][j] * x[j];
        x[i] /= LU[i][i];
    }
}

template <int R>
__device__ void lu_solve_transpose(double LU[R][R], int piv[R], const double *b, double *x) {
    /* Solve A^T x = b where PA = LU.
     * A^T = U^T L^T P, so: solve U^T y = b, then L^T w = y, then x = P^T w. */
    double y[R];
    for (int i = 0; i < R; i++) {
        y[i] = b[i];
        for (int j = 0; j < i; j++) y[i] -= LU[j][i] * y[j];
        y[i] /= LU[i][i];
    }
    double w[R];
    for (int i = R-1; i >= 0; i--) {
        w[i] = y[i];
        for (int j = i+1; j < R; j++) w[i] -= LU[j][i] * w[j];
    }
    for (int i = 0; i < R; i++) x[piv[i]] = w[i];
}

__device__ double solve3(double A[3][3], double b[3], double x[3]) {
    double det = A[0][0]*(A[1][1]*A[2][2]-A[1][2]*A[2][1])
               - A[0][1]*(A[1][0]*A[2][2]-A[1][2]*A[2][0])
               + A[0][2]*(A[1][0]*A[2][1]-A[1][1]*A[2][0]);
    if (fabs(det) < 1e-15) return 0.0;
    double inv = 1.0/det;
    x[0] = inv*(b[0]*(A[1][1]*A[2][2]-A[1][2]*A[2][1])
              - A[0][1]*(b[1]*A[2][2]-A[1][2]*b[2])
              + A[0][2]*(b[1]*A[2][1]-A[1][1]*b[2]));
    x[1] = inv*(A[0][0]*(b[1]*A[2][2]-A[1][2]*b[2])
              - b[0]*(A[1][0]*A[2][2]-A[1][2]*A[2][0])
              + A[0][2]*(A[1][0]*b[2]-b[1]*A[2][0]));
    x[2] = inv*(A[0][0]*(A[1][1]*b[2]-b[1]*A[2][1])
              - A[0][1]*(A[1][0]*b[2]-b[1]*A[2][0])
              + b[0]*(A[1][0]*A[2][1]-A[1][1]*A[2][0]));
    return det;
}

/* Solve the K x K system in the leading block of A, b and x by Cramer's
 * rule, for the K = R - 3 coordinates of a slice vertex. K = 3 is solve3.
 * Returns the determinant, or 0 when it is below 1e-15. */
template <int K>
__device__ double solve_k(double A[3][3], double b[3], double x[3]);

template <>
__device__ double solve_k<3>(double A[3][3], double b[3], double x[3]) {
    return solve3(A, b, x);
}

template <>
__device__ double solve_k<2>(double A[3][3], double b[3], double x[3]) {
    double det = A[0][0]*A[1][1] - A[0][1]*A[1][0];
    if (fabs(det) < 1e-15) return 0.0;
    double inv = 1.0/det;
    x[0] = inv*(b[0]*A[1][1] - A[0][1]*b[1]);
    x[1] = inv*(A[0][0]*b[1] - b[0]*A[1][0]);
    return det;
}

template <>
__device__ double solve_k<1>(double A[3][3], double b[3], double x[3]) {
    double det = A[0][0];
    if (fabs(det) < 1e-15) return 0.0;
    double inv = 1.0/det;
    x[0] = inv*b[0];
    return det;
}

/* At rank 3 the slice of a tile is the single point t0: no system to solve,
 * and the determinant of the empty matrix is 1. */
template <>
__device__ double solve_k<0>(double A[3][3], double b[3], double x[3]) {
    return 1.0;
}

/* Main kernel */

/* R is the rank of the six sensors. GB holds the six sensors at the R
 * wavelengths of a tile, and its first R rows are the R x R tile. A slice
 * of a tile has dimension R - 3, so each of its vertices lies on R - 3 of
 * the 2R planes t = 0 and t = 1: R - 3 coordinates are 0 or 1 and three
 * are free. At rank 6 these are the triples of 12 planes. */
template <int R>
__global__ void mmb_kernel(
    long long tile_offset,
    long long tiles_this_launch,
    double *d_ypts,
    int    *d_vert_count,
    int    *d_tile_count
) {
    constexpr int K = R - 3;
    constexpr int nsets = nchoosek(2 * R, K);
    long long local_tid = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (local_tid >= tiles_this_launch) return;
    long long tid = tile_offset + local_tid;

    int n = d_n;
    int basis[R];
    unrank_lex(tid, n, R, basis);

    /* Build GB */
    double GB[D][R];
    for (int c = 0; c < R; c++) {
        int g = basis[c];
        for (int r = 0; r < D; r++)
            GB[r][c] = d_G6[r * MAX_N + g];
    }

    /* LU factorize the first R rows */
    double LU[R][R];
    memcpy(LU, GB, sizeof(LU));
    int piv[R];
    if (lu<R>(LU, piv) != 0) return;

    /* Solve GB^T * v = hB for the dual vector using the existing LU factors. */
    double hB[R], v[R];
    for (int i = 0; i < R; i++) hB[i] = d_h6[basis[i]];
    lu_solve_transpose<R>(LU, piv, hB, v);
    /* Refine transpose solve */
    {
        double rv[R];
        for (int i = 0; i < R; i++) {
            rv[i] = hB[i];
            for (int j = 0; j < R; j++) rv[i] -= GB[j][i] * v[j];
        }
        double dv[R];
        lu_solve_transpose<R>(LU, piv, rv, dv);
        for (int i = 0; i < R; i++) v[i] += dv[i];
    }

    /* Translation via reduced costs */
    double cB[D] = {0,0,0,0,0,0};
    for (int j = 0; j < n; j++) {
        int skip = 0;
        for (int b = 0; b < R; b++) if (basis[b] == j) { skip = 1; break; }
        if (skip) continue;
        double rc = d_h6[j];
        for (int r = 0; r < R; r++) rc -= v[r] * d_G6[r * MAX_N + j];
        if (rc > 0)
            for (int r = 0; r < D; r++) cB[r] += d_G6[r * MAX_N + j];
    }

    /* Bounds check */
    double rhs3[3], M33[3][3], y3[3], t0[R];
    for (int r = 0; r < 3; r++) rhs3[r] = d_z0[r] - cB[r];
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) {
            M33[i][j] = 0;
            for (int k = 0; k < R; k++) M33[i][j] += GB[i][k] * GB[j][k];
        }
    if (fabs(solve3(M33, rhs3, y3)) < 1e-30) return;
    /* Refine y3 */
    {
        double ry[3];
        for (int i = 0; i < 3; i++) {
            ry[i] = rhs3[i];
            for (int j = 0; j < 3; j++) ry[i] -= M33[i][j] * y3[j];
        }
        double dy[3];
        solve3(M33, ry, dy);
        for (int i = 0; i < 3; i++) y3[i] += dy[i];
    }
    for (int i = 0; i < R; i++) {
        t0[i] = 0;
        for (int r = 0; r < 3; r++) t0[i] += GB[r][i] * y3[r];
    }
    for (int i = 0; i < R; i++)
        if (t0[i] < -1.5 || t0[i] > 2.5) return;

    /* Compute cross-section vertices for the remaining tiles. */

    /* Null space: NS = invGB(:, 4:R) (0-indexed columns 3 to R-1).
     * Compute these columns with R - 3 back-solves. */
    double NS[R][3];
    for (int c = 0; c < K; c++) {
        double rhs[R] = {0};
        rhs[c + 3] = 1.0;
        double sol[R];
        lu_solve<R>(LU, piv, rhs, sol);
        /* Iterative refinement: r = rhs - GB*sol, then correct */
        double res[R];
        for (int i = 0; i < R; i++) {
            res[i] = rhs[i];
            for (int j = 0; j < R; j++) res[i] -= GB[i][j] * sol[j];
        }
        double delta[R];
        lu_solve<R>(LU, piv, res, delta);
        for (int i = 0; i < R; i++) sol[i] += delta[i];
        for (int r = 0; r < R; r++) NS[r][c] = sol[r];
    }

    /* Constraints: [NS; -NS] * s <= [1-t0; t0] */
    double Ain[2 * R][3], bin_[2 * R];
    for (int r = 0; r < R; r++) {
        for (int c = 0; c < K; c++) {
            Ain[r][c] = NS[r][c];
            Ain[r+R][c] = -NS[r][c];
        }
        bin_[r] = 1.0 - t0[r];
        bin_[r+R] = t0[r];
    }

    /* A2 = GB(3:5,:), c2 = cB(3:5) */
    double A2[3][R], c2[3];
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < R; c++) A2[r][c] = GB[r+3][c];
        c2[r] = cB[r+3];
    }

    /* Enumerate vertices */
    double lypts[MAX_VPTS][3];
    int nv = 0;

    int hit_max_vpts = 0;
    for (int tt = 0; tt < nsets; tt++) {
        if (nv >= MAX_VPTS) {
            hit_max_vpts = 1;
            break;
        }
        double A3[3][3], b3[3];
        for (int i = 0; i < K; i++) {
            int p = d_plane_sets[tt][i];
            for (int j = 0; j < K; j++) A3[i][j] = Ain[p][j];
            b3[i] = bin_[p];
        }
        double sv[3];
        if (fabs(solve_k<K>(A3, b3, sv)) < 1e-15) continue;
        /* Refinement of the K x K solve */
        {
            double r3[3];
            for (int i = 0; i < K; i++) {
                r3[i] = b3[i];
                for (int j = 0; j < K; j++) r3[i] -= A3[i][j] * sv[j];
            }
            double dv[3];
            solve_k<K>(A3, r3, dv);
            for (int i = 0; i < K; i++) sv[i] += dv[i];
        }


        /* Physical reflectance check: t = t0 + NS*s must be in [0,1] */
        double t[R];
        for (int r = 0; r < R; r++) {
            t[r] = t0[r];
            for (int c = 0; c < K; c++) t[r] += NS[r][c]*sv[c];
        }
        /* Reject non-finite reflectance values. NaN values can pass the later
         * bound and color-match checks because comparisons with NaN are false. */
        int finite_ok = 1;
        for (int r = 0; r < R; r++)
            if (!isfinite(t[r])) { finite_ok = 0; break; }
        if (!finite_ok) { atomicAdd(&d_rejected_nonfinite, 1ULL); continue; }
        int ok = 1;
        for (int r = 0; r < R; r++) {
            if (t[r] < -1e-9 || t[r] > 1.0 + 1e-9)
                { ok = 0; break; }
        }
        if (!ok) { atomicAdd(&d_rejected_physical, 1ULL); continue; }

        /* Verify color match: G1*rho must equal z0 */
        double z_check[3] = {0, 0, 0};
        for (int r = 0; r < 3; r++) {
            z_check[r] = cB[r];
            for (int k = 0; k < R; k++)
                z_check[r] += GB[r][k] * t[k];
        }
        double z_err = 0;
        for (int r = 0; r < 3; r++) {
            double d = z_check[r] - d_z0[r];
            z_err += d * d;
        }
        if (z_err > d_zmatch_tol) { atomicAdd(&d_rejected_zmatch, 1ULL); continue; }

        /* Map to illuminant-2 color space: y = A2*t + c2 */
        for (int r = 0; r < 3; r++) {
            lypts[nv][r] = c2[r];
            for (int c = 0; c < R; c++) lypts[nv][r] += A2[r][c] * t[c];
        }
        nv++;
    }

    if (hit_max_vpts) atomicAdd(&d_max_vpts_hits, 1ULL);
    /* A slice of dimension R - 3 needs R - 2 vertices: 4 at rank 6 */
    if (nv < R - 2) return;

    /* Write to global buffer */
    int start = atomicAdd(d_vert_count, nv);
    if (start + nv <= d_max_verts) {
        for (int v = 0; v < nv; v++) {
            d_ypts[(start+v)*3+0] = lypts[v][0];
            d_ypts[(start+v)*3+1] = lypts[v][1];
            d_ypts[(start+v)*3+2] = lypts[v][2];
        }
    }
    atomicAdd(d_tile_count, 1);
}

/* Host */

/* Rank of the six sensors over n wavelengths by MATLAB's rule in rank and
 * orth: the singular values above max(n,6) * eps(largest). One-sided Jacobi
 * makes the six columns of the n x 6 generator matrix orthogonal, and the
 * column norms are then the singular values. On return the columns of Q
 * are in order of decreasing singular value. The first r are an orthonormal
 * basis of the space the generators span. Each of the other 6 - r is a
 * dependence w among the six sensors, with w' * G6 near 0. */
int sensor_rank(double G6[D][MAX_N], int n, double Q[D][D], double s_out[D], double *tol_out) {
    static double A[D][MAX_N];
    memcpy(A, G6, sizeof(A));
    double V[D][D];
    for (int i = 0; i < D; i++)
        for (int j = 0; j < D; j++) V[i][j] = (i == j) ? 1.0 : 0.0;
    for (int pass = 0; pass < 100; pass++) {
        int rotated = 0;
        for (int p = 0; p < D - 1; p++)
            for (int q = p + 1; q < D; q++) {
                double a = 0, b = 0, c = 0;
                for (int j = 0; j < n; j++) {
                    a += A[p][j] * A[p][j];
                    b += A[q][j] * A[q][j];
                    c += A[p][j] * A[q][j];
                }
                if (fabs(c) <= DBL_EPSILON * sqrt(a * b)) continue;
                rotated = 1;
                double zeta = (b - a) / (2 * c);
                double t = (zeta >= 0 ? 1.0 : -1.0) / (fabs(zeta) + sqrt(1 + zeta * zeta));
                double cs = 1 / sqrt(1 + t * t), sn = cs * t;
                for (int j = 0; j < n; j++) {
                    double x = A[p][j], y = A[q][j];
                    A[p][j] = cs * x - sn * y;
                    A[q][j] = sn * x + cs * y;
                }
                for (int i = 0; i < D; i++) {
                    double x = V[i][p], y = V[i][q];
                    V[i][p] = cs * x - sn * y;
                    V[i][q] = sn * x + cs * y;
                }
            }
        if (!rotated) break;
    }
    double s[D];
    int order[D];
    for (int k = 0; k < D; k++) {
        s[k] = 0;
        for (int j = 0; j < n; j++) s[k] += A[k][j] * A[k][j];
        s[k] = sqrt(s[k]);
        order[k] = k;
    }
    for (int i = 0; i < D; i++)
        for (int j = i + 1; j < D; j++)
            if (s[order[j]] > s[order[i]]) { int t = order[i]; order[i] = order[j]; order[j] = t; }
    double smax = s[order[0]];
    double tol = (n > D ? n : D) * (smax > 0 ? ldexp(1.0, ilogb(smax) - 52) : 0);
    int r = 0;
    for (int k = 0; k < D; k++) {
        for (int i = 0; i < D; i++) Q[i][k] = V[i][order[k]];
        s_out[k] = s[order[k]];
        if (s[order[k]] > tol) r++;
    }
    *tol_out = tol;
    return r;
}

int main(int argc, char **argv) {
    const char *datafile = NULL;
    const char *outfile = NULL;
    long long max_verts = MAX_VERTS_DEFAULT;
    int chunk_id = 0;
    int total_chunks = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--data") == 0 && i+1 < argc) datafile = argv[++i];
        else if (strcmp(argv[i], "--output") == 0 && i+1 < argc) outfile = argv[++i];
        else if (strcmp(argv[i], "--max-verts") == 0 && i+1 < argc) max_verts = atoll(argv[++i]);
        else if (strcmp(argv[i], "--chunk") == 0 && i+1 < argc) chunk_id = atoi(argv[++i]);
        else if (strcmp(argv[i], "--nchunks") == 0 && i+1 < argc) total_chunks = atoi(argv[++i]);
    }
    if (!datafile) {
        fprintf(stderr, "Usage: mmb_exact --data <file> [--output <file>] [--max-verts <n>] [--chunk <id>] [--nchunks <n>]\n");
        return 1;
    }
    if (max_verts <= 0 || max_verts > INT_MAX) {
        fprintf(stderr, "Invalid --max-verts %lld; expected 1..%d\n", max_verts, INT_MAX);
        return 1;
    }
    if (total_chunks < 1 || chunk_id < 0 || chunk_id >= total_chunks) {
        fprintf(stderr, "Invalid chunk arguments: --chunk %d --nchunks %d\n", chunk_id, total_chunks);
        return 1;
    }

    /* Derive the output name: generators_X.txt -> mmb_X.txt */
    char auto_outfile[512];
    if (!outfile) {
        const char *base = strrchr(datafile, '/');
        base = base ? base + 1 : datafile;
        int nw;
        if (strncmp(base, "generators_", 11) == 0) {
            nw = snprintf(auto_outfile, sizeof(auto_outfile), "mmb_%s", base + 11);
        } else {
            nw = snprintf(auto_outfile, sizeof(auto_outfile), "mmb_%s", base);
        }
        if (nw < 0 || (size_t)nw >= sizeof(auto_outfile)) {
            fprintf(stderr, "Output file name too long for %s\n", datafile);
            return 1;
        }
        /* Append _chunkN when splitting the run into chunks. */
        if (total_chunks > 1) {
            char temp[512];
            char *dot = strrchr(auto_outfile, '.');
            if (dot) {
                int base_len = (int)(dot - auto_outfile);
                nw = snprintf(temp, sizeof(temp), "%.*s_chunk%d%s",
                              base_len, auto_outfile, chunk_id, dot);
            } else {
                nw = snprintf(temp, sizeof(temp), "%s_chunk%d", auto_outfile, chunk_id);
            }
            if (nw < 0 || (size_t)nw >= sizeof(temp)) {
                fprintf(stderr, "Output file name too long for %s\n", datafile);
                return 1;
            }
            nw = snprintf(auto_outfile, sizeof(auto_outfile), "%s", temp);
            if (nw < 0 || (size_t)nw >= sizeof(auto_outfile)) {
                fprintf(stderr, "Output file name too long for %s\n", datafile);
                return 1;
            }
        }
        outfile = auto_outfile;
    }
    if (strcmp(outfile, datafile) == 0) {
        fprintf(stderr, "--output must not overwrite --data\n");
        return 1;
    }
    remove(outfile);

    printf("=== Exact MMB -- Fully GPU ===\n\n");
    printf("  Input:  %s\n", datafile);
    printf("  Output: %s\n", outfile);
    if (total_chunks > 1)
        printf("  Chunk:  %d of %d\n", chunk_id + 1, total_chunks);
    printf("\n");

    /* Load data */
    int n = 0;
    static double G6_h[D][MAX_N];
    static double h6_h[MAX_N];
    double z0_h[3];
    char metadata[8192] = "";
    char metadata_last[256] = "";
    size_t metadata_len = 0;
    {
        FILE *f = fopen(datafile, "r");
        if (!f) { fprintf(stderr, "Cannot open %s\n", datafile); return 1; }

        /* Preserve input comments as metadata and retain the last one for display. */
        char line[512] = "";
        char *n_line = NULL;
        while (fgets(line, sizeof(line), f)) {
            char *p = line;
            while (*p == ' ' || *p == '\t') p++;
            if (*p == '\n' || *p == '\r' || *p == '\0') continue;
            if (*p != '%') { n_line = p; break; }
            int len = strlen(line);
            while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
                line[--len] = '\0';

            const char *comment = p + 1;
            snprintf(metadata_last, sizeof(metadata_last), "%s", comment);
            int nw = snprintf(metadata + metadata_len, sizeof(metadata) - metadata_len,
                              "%%%s\n", comment);
            if (nw < 0 || (size_t)nw >= sizeof(metadata) - metadata_len) {
                fprintf(stderr, "Metadata too long in %s\n", datafile);
                fclose(f);
                return 1;
            }
            metadata_len += (size_t)nw;
        }

        /* First non-comment line contains n */
        if (!n_line || sscanf(n_line, "%d", &n) != 1) {
            fprintf(stderr, "Failed to read n from %s\n", datafile);
            fclose(f);
            return 1;
        }
        if (n < D || n > MAX_N) {
            fprintf(stderr, "Invalid n=%d in %s; expected %d..%d\n", n, datafile, D, MAX_N);
            fclose(f);
            return 1;
        }
        if (fscanf(f, "%lf %lf %lf", &z0_h[0], &z0_h[1], &z0_h[2]) != 3) {
            fprintf(stderr, "Failed to read z0 from %s\n", datafile);
            fclose(f);
            return 1;
        }
        for (int r = 0; r < 3; r++) {
            if (!isfinite(z0_h[r])) {
                fprintf(stderr, "Invalid z0 value in %s\n", datafile);
                fclose(f);
                return 1;
            }
        }

        for (int j = 0; j < n; j++) {
            double wl;
            if (fscanf(f, "%lf", &wl) != 1 || !isfinite(wl)) {
                fprintf(stderr, "Failed to read wavelength for row %d from %s\n", j + 1, datafile);
                fclose(f);
                return 1;
            }
            for (int r = 0; r < 6; r++) {
                if (fscanf(f, "%lf", &G6_h[r][j]) != 1 || !isfinite(G6_h[r][j])) {
                    fprintf(stderr, "Failed to read generator %d for row %d from %s\n", r + 1, j + 1, datafile);
                    fclose(f);
                    return 1;
                }
            }
        }
        fclose(f);
        for (int j = 0; j < n; j++) h6_h[j] = ldexp(1.0, -(j + 1));
    }

    if (metadata_last[0]) printf("  Metadata:%s\n", metadata_last);

    double Q[D][D], sv_h[D], rank_tol;
    int rank = sensor_rank(G6_h, n, Q, sv_h, &rank_tol);
    printf("  Sensor rank: %d (smallest singular value %.3e, tolerance %.3e)\n",
           rank, sv_h[D - 1], rank_tol);
    if (rank < 3) {
        fprintf(stderr, "Sensor rank %d in %s; the tiling needs rank 3 or more\n", rank, datafile);
        return 1;
    }

    /* Rank 6 uses the generators as read. Below 6, the first rank rows must
     * span the space the generators span. Rows 0-2 are the first response.
     * Of the second response's three channels, the 6 - rank whose part of
     * the dependences in Q has the largest determinant move to the end, so
     * that each is a combination of the rows before it. order[i] is the
     * channel in row 3 + i. The output keeps the channels in their order. */
    int order[3] = {0, 1, 2};
    char rank_line[64] = "";
    if (rank < D) {
        int m = D - rank, moved = 0;
        double best = -1;
        for (int set = 0; set < 8; set++) {
            int ch[3], k = 0;
            for (int c = 0; c < 3; c++) if (set >> c & 1) ch[k++] = c;
            if (k != m) continue;
            /* The m x m minor, padded to 3 x 3 with the identity */
            double W[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
            for (int a = 0; a < m; a++)
                for (int b = 0; b < m; b++) W[a][b] = Q[3 + ch[a]][rank + b];
            double det = fabs(W[0][0]*(W[1][1]*W[2][2]-W[1][2]*W[2][1])
                            - W[0][1]*(W[1][0]*W[2][2]-W[1][2]*W[2][0])
                            + W[0][2]*(W[1][0]*W[2][1]-W[1][1]*W[2][0]));
            if (det > best) { best = det; moved = set; }
        }
        int k = 0;
        for (int c = 0; c < 3; c++) if (!(moved >> c & 1)) order[k++] = c;
        for (int c = 0; c < 3; c++) if (moved >> c & 1) order[k++] = c;
        static double G2_h[3][MAX_N];
        memcpy(G2_h, G6_h[3], sizeof(G2_h));
        for (int i = 0; i < 3; i++) memcpy(G6_h[3 + i], G2_h[order[i]], sizeof(G2_h[0]));
        printf("  Second response channels in rows 4-6: %d %d %d\n",
               order[0] + 1, order[1] + 1, order[2] + 1);
        snprintf(rank_line, sizeof(rank_line), "%% rank=%d, tiles of %d wavelengths\n", rank, rank);
    }

    long long total = nchoosek(n, rank);
    long long my_start = (long long)chunk_id * total / total_chunks;
    long long my_end = (long long)(chunk_id + 1) * total / total_chunks;
    long long my_tiles = my_end - my_start;

    /* Squared color-match tolerance: 1e-20 * ||z0||^2.
     * Apply a floor of 1e-28 for targets near zero. */
    double z0_norm2 = z0_h[0]*z0_h[0] + z0_h[1]*z0_h[1] + z0_h[2]*z0_h[2];
    double zmatch_tol = 1e-20 * z0_norm2;
    if (zmatch_tol < 1e-28) zmatch_tol = 1e-28;

    printf("  n=%d, C(%d,%d) = %lld tiles\n", n, n, rank, total);
    if (total_chunks > 1)
        printf("  This chunk: tiles %lld-%lld (%lld tiles)\n", my_start, my_end - 1, my_tiles);
    printf("  z0 = [%.4f, %.4f, %.4f]\n", z0_h[0], z0_h[1], z0_h[2]);
    printf("  z-match tol: ||dz||^2 <= %.3e (relative 1e-10 of ||z0||)\n\n", zmatch_tol);

    /* Every set of rank - 3 of the 2 * rank constraint planes, in
     * lexicographic order: the 220 triples of 12 planes at rank 6. */
    int h_sets[MAX_PLANE_SETS][3] = {{0}};
    for (int i = 0; i < nchoosek(2 * rank, rank - 3); i++)
        unrank_lex(i, 2 * rank, rank - 3, h_sets[i]);

    /* Copy to GPU constants */
    static double flat_G6[D * MAX_N];
    memset(flat_G6, 0, sizeof(flat_G6));
    for (int r = 0; r < 6; r++)
        for (int j = 0; j < n; j++)
            flat_G6[r * MAX_N + j] = G6_h[r][j];

    CUDA_CHECK(cudaMemcpyToSymbol(d_G6, flat_G6, sizeof(flat_G6)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_h6, h6_h, n * sizeof(double)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_z0, z0_h, 3 * sizeof(double)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_n, &n, sizeof(int)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_plane_sets, h_sets, sizeof(h_sets)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_max_verts, &max_verts, sizeof(max_verts)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_zmatch_tol, &zmatch_tol, sizeof(zmatch_tol)));

    /* Allocate output */
    double *d_ypts;
    int *d_vc, *d_tc;
    size_t yb = (size_t)max_verts * 3 * sizeof(double);
    printf("  Vertex buffer: %.1f GB\n", yb / 1e9);
    CUDA_CHECK(cudaMalloc(&d_ypts, yb));
    CUDA_CHECK(cudaMalloc(&d_vc, sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_tc, sizeof(int)));
    CUDA_CHECK(cudaMemset(d_vc, 0, sizeof(int)));
    CUDA_CHECK(cudaMemset(d_tc, 0, sizeof(int)));
    unsigned long long zero = 0;
    CUDA_CHECK(cudaMemcpyToSymbol(d_rejected_physical, &zero, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_rejected_zmatch, &zero, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_rejected_nonfinite, &zero, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_max_vpts_hits, &zero, sizeof(unsigned long long)));

    /* Launch in grid-sized batches (gridDim.x max = 2^31-1) */
    int tpb = 256;
    long long max_blocks = (1ULL << 31) - 1;
    long long max_per_launch = max_blocks * tpb;
    int nLaunches = (int)((my_tiles + max_per_launch - 1) / max_per_launch);

    printf("  Threads/block: %d, Launches: %d\n\n", tpb, nLaunches);

    struct timespec ts0, ts1;
    clock_gettime(CLOCK_MONOTONIC, &ts0);

    for (int li = 0; li < nLaunches; li++) {
        long long launch_offset = my_start + (long long)li * max_per_launch;
        long long tiles_this = my_tiles - (long long)li * max_per_launch;
        if (tiles_this > max_per_launch) tiles_this = max_per_launch;
        int blocks = (int)((tiles_this + tpb - 1) / tpb);

        printf("  Launch %d/%d: tiles %lld-%lld (%d blocks)\n",
               li+1, nLaunches, launch_offset, launch_offset+tiles_this-1, blocks);

        switch (rank) {
        case 6: mmb_kernel<6><<<blocks, tpb>>>(launch_offset, tiles_this, d_ypts, d_vc, d_tc); break;
        case 5: mmb_kernel<5><<<blocks, tpb>>>(launch_offset, tiles_this, d_ypts, d_vc, d_tc); break;
        case 4: mmb_kernel<4><<<blocks, tpb>>>(launch_offset, tiles_this, d_ypts, d_vc, d_tc); break;
        case 3: mmb_kernel<3><<<blocks, tpb>>>(launch_offset, tiles_this, d_ypts, d_vc, d_tc); break;
        }
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());
    }

    clock_gettime(CLOCK_MONOTONIC, &ts1);
    double elapsed = (ts1.tv_sec-ts0.tv_sec) + (ts1.tv_nsec-ts0.tv_nsec)*1e-9;

    int h_vc, h_tc;
    CUDA_CHECK(cudaMemcpy(&h_vc, d_vc, sizeof(int), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(&h_tc, d_tc, sizeof(int), cudaMemcpyDeviceToHost));
    unsigned long long h_rp, h_rz, h_rnf, h_mv;
    CUDA_CHECK(cudaMemcpyFromSymbol(&h_rp, d_rejected_physical, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemcpyFromSymbol(&h_rz, d_rejected_zmatch, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemcpyFromSymbol(&h_rnf, d_rejected_nonfinite, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemcpyFromSymbol(&h_mv, d_max_vpts_hits, sizeof(unsigned long long)));

    printf("\n  === Results ===\n");
    printf("  Tiles tested:       %lld\n", my_tiles);
    printf("  Tiles intersecting: %d\n", h_tc);
    printf("  Vertices collected: %d\n", h_vc);
    printf("  Rejected (physical): %llu\n", h_rp);
    printf("  Rejected (z-match):  %llu\n", h_rz);
    printf("  Rejected (non-finite): %llu\n", h_rnf);
    printf("  Hit MAX_VPTS:       %llu\n", h_mv);
    printf("  GPU time:           %.2f seconds\n", elapsed);
    printf("  Throughput:         %.2f billion tiles/sec\n\n", my_tiles/elapsed/1e9);

    if (h_mv > 0) {
        fprintf(stderr, "ERROR: per-tile vertex buffer hit MAX_VPTS=%d in %llu tile(s). Increase MAX_VPTS and rebuild.\n",
                MAX_VPTS, h_mv);
        CUDA_CHECK(cudaFree(d_ypts));
        CUDA_CHECK(cudaFree(d_vc));
        CUDA_CHECK(cudaFree(d_tc));
        return 2;
    }
    if (h_vc < 0 || (long long)h_vc > max_verts) {
        fprintf(stderr, "ERROR: vertex buffer overflow (%d collected, capacity %lld). Increase --max-verts or split into more chunks.\n",
                h_vc, max_verts);
        CUDA_CHECK(cudaFree(d_ypts));
        CUDA_CHECK(cudaFree(d_vc));
        CUDA_CHECK(cudaFree(d_tc));
        return 2;
    }

    /* Copy vertices and write */
    printf("  Copying %.1f MB to host...\n", h_vc*24.0/1e6);
    double *h_ypts = (double*)malloc((size_t)h_vc * 3 * sizeof(double));
    if (h_vc > 0 && !h_ypts) {
        fprintf(stderr, "Failed to allocate host vertex buffer\n");
        CUDA_CHECK(cudaFree(d_ypts));
        CUDA_CHECK(cudaFree(d_vc));
        CUDA_CHECK(cudaFree(d_tc));
        return 1;
    }
    if (h_vc > 0) {
        CUDA_CHECK(cudaMemcpy(h_ypts, d_ypts, (size_t)h_vc*3*sizeof(double),
                              cudaMemcpyDeviceToHost));
    }

    /* Write text output */
    FILE *fo = fopen(outfile, "w");
    if (!fo) {
        fprintf(stderr, "Cannot write %s\n", outfile);
        free(h_ypts);
        CUDA_CHECK(cudaFree(d_ypts));
        CUDA_CHECK(cudaFree(d_vc));
        CUDA_CHECK(cudaFree(d_tc));
        return 1;
    }
    fprintf(fo, "%% MMB vertices from CUDA kernel\n");
    fprintf(fo, "%% Input: %s\n", datafile);
    if (metadata[0]) fprintf(fo, "%s", metadata);
    fprintf(fo, "%s", rank_line);
    fprintf(fo, "%% n=%d, tiles_total=%lld, tiles_tested=%lld, tiles_intersecting=%d, vertices=%d\n",
            n, total, my_tiles, h_tc, h_vc);
    if (total_chunks > 1)
        fprintf(fo, "%% chunk=%d, nchunks=%d\n", chunk_id, total_chunks);
    fprintf(fo, "%% gpu_seconds=%.2f\n", elapsed);
    /* Second response channel c is in column col[c] of h_ypts */
    int col[3];
    for (int i = 0; i < 3; i++) col[order[i]] = i;
    for (int i = 0; i < h_vc; i++) {
        fprintf(fo, "%.17g %.17g %.17g\n",
                h_ypts[i*3+col[0]], h_ypts[i*3+col[1]], h_ypts[i*3+col[2]]);
    }
    /* Completion marker for tools/verify_chunk.sh and hull preflight.
     * Its count must match the header's vertices field and the data-row count. */
    fprintf(fo, "%% complete vertices=%d\n", h_vc);

    /* Check for write and close errors, including disk-full and quota errors.
     * Remove partial output and return an error if either operation fails. */
    fflush(fo);
    if (ferror(fo)) {
        fprintf(stderr, "ERROR: write failure on %s (disk full or quota exceeded?); removing partial output\n", outfile);
        fclose(fo);
        remove(outfile);
        free(h_ypts);
        CUDA_CHECK(cudaFree(d_ypts));
        CUDA_CHECK(cudaFree(d_vc));
        CUDA_CHECK(cudaFree(d_tc));
        return 2;
    }
    if (fclose(fo) != 0) {
        fprintf(stderr, "ERROR: close failure on %s (disk full or quota exceeded?); removing partial output\n", outfile);
        remove(outfile);
        free(h_ypts);
        CUDA_CHECK(cudaFree(d_ypts));
        CUDA_CHECK(cudaFree(d_vc));
        CUDA_CHECK(cudaFree(d_tc));
        return 2;
    }
    printf("  Written: %s\n\n", outfile);

    free(h_ypts);
    CUDA_CHECK(cudaFree(d_ypts));
    CUDA_CHECK(cudaFree(d_vc));
    CUDA_CHECK(cudaFree(d_tc));
    return 0;
}
