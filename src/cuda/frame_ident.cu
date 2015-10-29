#include <cuda_runtime.h>

#include "frame.h"

using namespace std;

namespace popart {

namespace identification {

struct matrix3x3
{
    float val[3][3];

    __host__ __device__
    matrix3x3( ) { }

    __host__ __device__
    matrix3x3( const float mx[3][3] ) {
        #pragma unroll
        for( int i=0; i<3; i++ ) {
            #pragma unroll
            for( int j=0; j<3; j++ ) {
                val[i][j] = mx[i][j];
            }
        }
    }

    __host__ __device__
    inline float& operator()(int y, int x) {
        return val[y][x];
    }

    __host__ __device__
    inline const float& operator()(int y, int x) const {
        return val[y][x];
    }
};

struct CutStruct
{
    float2 start;
    float2 stop;
    int    outOfBounds;
    float  beginSig;
    float  endSig;
    int    sigSize;
};

__host__ __device__
float det( const matrix3x3& m )
{
    float det =  m(0,0) * ( m(1,1) * m(2,2) - m(2,1) * m(1,2) )
               - m(0,1) * ( m(1,0) * m(2,2) - m(1,2) * m(2,0) )
               + m(0,2) * ( m(1,0) * m(2,1) - m(1,1) * m(2,0) ) ;

    return det;
}

__host__ __device__
bool invert_3x3( const matrix3x3& A, matrix3x3& result )
{
    float determinant =  popart::identification::det(A);

    if( determinant == 0 )
    {
        return false;
    }

    result(0,0) = (  A(1,1) * A(2,2) - A(1,2) * A(2,1) ) / determinant;
    result(1,0) = ( -A(1,0) * A(2,2) + A(2,0) * A(1,2) ) / determinant;
    result(2,0) = (  A(1,0) * A(2,1) - A(2,0) * A(1,1) ) / determinant;
    result(0,1) = ( -A(0,1) * A(2,2) + A(2,1) * A(0,2) ) / determinant;
    result(1,1) = (  A(0,0) * A(2,2) - A(2,0) * A(0,2) ) / determinant;
    result(2,1) = ( -A(0,0) * A(2,1) + A(2,0) * A(0,1) ) / determinant;
    result(0,2) = (  A(0,1) * A(1,2) - A(1,1) * A(0,2) ) / determinant;
    result(1,2) = ( -A(0,0) * A(1,2) + A(1,0) * A(0,2) ) / determinant;
    result(2,2) = (  A(0,0) * A(1,1) - A(1,0) * A(0,1) ) / determinant;
    return true;
}

__device__
void applyHomography( float& xRes, float& yRes, const matrix3x3& mHomography, const float x, const float y )
{
  float u = mHomography(0,0)*x + mHomography(0,1)*y + mHomography(0,2);
  float v = mHomography(1,0)*x + mHomography(1,1)*y + mHomography(1,2);
  float w = mHomography(2,0)*x + mHomography(2,1)*y + mHomography(2,2);
  xRes = u/w;
  yRes = v/w;
}

__device__
inline float getPixelBilinear( cv::cuda::PtrStepSzb src, float x, float y )
{
  int px = (int)x; // floor of x
  int py = (int)y; // floor of y

  // uint8_t p0 = src.ptr(py  )[px  ];
  uint8_t p1 = src.ptr(py  )[px  ];
  uint8_t p2 = src.ptr(py  )[px+1];
  uint8_t p3 = src.ptr(py+1)[px  ];
  uint8_t p4 = src.ptr(py+1)[px+1];

  // Calculate the weights for each pixel
  float fx  = x - (float)px;
  float fy  = y - (float)py;
  float fx1 = 1.0f - fx;
  float fy1 = 1.0f - fy;

  float w1 = fx1 * fy1;
  float w2 = fx  * fy1;
  float w3 = fx1 * fy;
  float w4 = fx  * fy;

  // Calculate the weighted sum of pixels (for each color channel)
  return ( p1 * w1 + p2 * w2 + p3 * w3 + p4 * w4 ) / 2.0f;
}

__device__
void extractSignalUsingHomography( float*               cut_ptr,
                                   cv::cuda::PtrStepSzb src,
                                   const matrix3x3&     mHomography,
                                   const matrix3x3&     mInvHomography )
{
    CutStruct* cut = reinterpret_cast<CutStruct*>( cut_ptr );
    float*     cut_signals = &cut_ptr[8];

    if( threadIdx.x == 0 ) {
        cut->outOfBounds = 0;
    }
    __syncthreads();

    float backProjStopX;
    float backProjStopY;

    popart::identification::applyHomography( backProjStopX, backProjStopY, mInvHomography, cut->stop.x, cut->stop.y );
  
    // Check whether the signal to be collected start at 0.0 and stop at 1.0
    bool comp;
    comp         = ( cut->beginSig != 0.0 );
    float xStart = comp ? backProjStopX * cut->beginSig : 0.0f;
    float yStart = comp ? backProjStopY * cut->beginSig : 0.0f;
    comp         = ( cut->endSig != 1.0 );
    float xStop  = comp ? backProjStopX * cut->endSig : backProjStopX; // xStop and yStop must not be normalised but the 
    float yStop  = comp ? backProjStopY * cut->endSig : backProjStopY; // norm([xStop;yStop]) is supposed to be close to 1.

    // Compute the steps stepX and stepY along x and y.
    const std::size_t nSamples = cut->sigSize;
    const float stepX = ( xStop - xStart ) / ( nSamples - 1.0f );
    const float stepY = ( yStop - yStart ) / ( nSamples - 1.0f );

    float x =  xStart;
    float y =  yStart;
  
    for( std::size_t i = threadIdx.x; i < nSamples; i += 32 ) {
        float xRes;
        float yRes;

        // [xRes;yRes;1] ~= mHomography*[x;y;1.0]
        popart::identification::applyHomography( xRes, yRes, mHomography, x, y );

        bool breaknow = ( xRes < 1.0 && xRes > src.cols-1 && yRes < 1.0 && yRes > src.rows-1 );

        if( __any( breaknow ) )
        {
            if( threadIdx.x == 0 ) cut->outOfBounds = 1;
            return;
        }

        // Bilinear interpolation
        cut_signals[i] = popart::identification::getPixelBilinear( src, xRes, yRes );
    
        x += stepX;
        y += stepY;
    }
}

__global__
void idGetSignals( matrix3x3 mHomography, matrix3x3 mInvHomography, cv::cuda::PtrStepSzb src, float* d, const int vCutsSize, const int vCutMaxVecLen )
{
    int myCut = blockIdx.x * 32 + threadIdx.y;

    if( myCut >= vCutsSize ) return; // out of bounds

    float* cut = &d[myCut * vCutMaxVecLen];

    extractSignalUsingHomography( cut, src, mHomography, mInvHomography);
}

__global__
void idComputeResult( float* result, int* resCt, float* d, const int vCutsSize, const int vCutMaxVecLen )
{
    __shared__ float signal_sum[32];
    __shared__ int   count_sum[32];

    if( threadIdx.y == 0 ) {
        signal_sum[threadIdx.x] = 0;
    }
    __syncthreads();

    int myPair = blockIdx.x * 32 + threadIdx.y;
    int j      = __float2int_rd( 1.0f + __fsqrt_rd(1.0f+8.0f*myPair) ) / 2;
    int i      = myPair - j*(j-1)/2;

    if( i >= vCutsSize || j >= vCutsSize ) return;

    float val    = 0.0f;
    float* l     = &d[i * vCutMaxVecLen];
    float* r     = &d[j * vCutMaxVecLen];
    bool   comp  = ( threadIdx.x < vCutMaxVecLen ) &&
                   not reinterpret_cast<CutStruct*>(l)->outOfBounds &&
                   not reinterpret_cast<CutStruct*>(r)->outOfBounds;
    int    limit = comp ? reinterpret_cast<CutStruct*>(l)->sigSize : 0;
    for( int offset = threadIdx.x; offset < limit; offset += 32 ) {
        float square = comp ? l[8+offset]-r[8+offset] : 0.0f;
        val = __fmaf_rn( square, square, val ); // val += ( square * square );
    }
    int   ct = comp ? 1 : 0;
    __syncthreads();
    val += __shfl_down( 16, val );
    val += __shfl_down(  8, val );
    val += __shfl_down(  4, val );
    val += __shfl_down(  2, val );
    val += __shfl_down(  1, val );
    ct  += __shfl_down( 16, ct );
    ct  += __shfl_down(  8, ct );
    ct  += __shfl_down(  4, ct );
    ct  += __shfl_down(  2, ct );
    ct  += __shfl_down(  1, ct );
    if( threadIdx.x == 0 ) {
        signal_sum[threadIdx.y] = val;
        count_sum [threadIdx.y] = ct;
    }
    __syncthreads();
    if( threadIdx.y == 0 ) {
        val = signal_sum[threadIdx.x];
        val += __shfl_down( 16, val );
        val += __shfl_down(  8, val );
        val += __shfl_down(  4, val );
        val += __shfl_down(  2, val );
        val += __shfl_down(  1, val );
        ct  = count_sum[threadIdx.x];
        ct  += __shfl_down( 16, ct );
        ct  += __shfl_down(  8, ct );
        ct  += __shfl_down(  4, ct );
        ct  += __shfl_down(  2, ct );
        ct  += __shfl_down(  1, ct );
        if( threadIdx.x == 0 ) {
            atomicAdd( result, val );
            atomicAdd( resCt, ct );
        }
    }
}

} // namespace identification


__host__
double Frame::idCostFunction( const float hom[3][3], const int vCutsSize, const int vCutMaxVecLen, bool& readable )
{
    readable  = true;

    // Get the rectified signals along the image cuts
    popart::identification::matrix3x3 mHomography( hom );
    popart::identification::matrix3x3 mInvHomography;
    popart::identification::invert_3x3( mHomography, mInvHomography );

    dim3 block;
    dim3 grid;
    block.x = 32; // we use this to sum up signals
    block.y = 32; // we can use some shared memory/warp magic for summing
    block.z = 0;
    grid.x  = grid_divide( vCutsSize, 32 );
    grid.y  = 0;
    grid.z  = 0;

    identification::idGetSignals
        <<<grid,block,0,_stream>>>
        ( mHomography, mInvHomography, _d_plane, _d_intermediate.data, vCutsSize, vCutMaxVecLen );

    int numPairs = vCutsSize*(vCutsSize+1)/2;
    block.x = 32; // we use this to sum up signals
    block.y = 32; // we can use some shared memory/warp magic for summing
    block.z = 0;
    grid.x  = grid_divide( numPairs, 32 );
    grid.y  = 0;
    grid.z  = 0;

    // float* device_result = MUSTBEALLOCATED;
    // int*   device_resct  = MUSTBEALLOCATED;
    float* device_result = 0;
    int*   device_resct  = 0;

    identification::idComputeResult
        <<<grid,block,0,_stream>>>
        ( device_result, device_resct, _d_intermediate.data, vCutsSize, vCutMaxVecLen );

    float res     = 0;
    int   resSize = 0;
    // float res     = COPYFROMDEVICE( device_result );
    // int   resSize = COPYFROMDEVICE( device_resct );

    // If no cut-pair has been found within the image bounds.
    if ( resSize == 0) {
        readable  = false;
        return std::numeric_limits<double>::max();
    } else {
        // normalize, dividing by the total number of pairs in the image bounds.
        return res /= resSize;
    }
}

__host__
size_t Frame::getIntermediatePlaneByteSize( ) const
{
    return _d_intermediate.rows * _d_intermediate.step;
}

__host__
void Frame::uploadCuts( std::vector<cctag::ImageCut>& vCuts, const int vCutMaxVecLen )
{
    using namespace popart::identification;

    float* d = _h_intermediate.data;
    std::vector<cctag::ImageCut>::const_iterator vit  = vCuts.begin();
    std::vector<cctag::ImageCut>::const_iterator vend = vCuts.end();
    for( ; vit!=vend; vit++ ) {
        CutStruct* csptr = (CutStruct*)d;
        csptr->start.x     = vit->start().getX();
        csptr->start.y     = vit->start().getY();
        csptr->stop.x      = vit->stop().getX();
        csptr->stop.y      = vit->stop().getY();
        csptr->outOfBounds = vit->outOfBounds() ? 1 : 0;
        csptr->beginSig    = vit->beginSig();
        csptr->endSig      = vit->endSig();
        csptr->sigSize     = vit->imgSignal().size();
        int idx = 8;
        boost::numeric::ublas::vector<double>::const_iterator sit  = vit->imgSignal().begin();
        boost::numeric::ublas::vector<double>::const_iterator send = vit->imgSignal().end();
        for( ; sit!=send; sit++ ) {
            d[idx] = *sit;
            idx++;
        }
        assert( idx <= vCutMaxVecLen );

        d += vCutMaxVecLen;
    }

    POP_CUDA_MEMCPY_TO_DEVICE_ASYNC( _d_intermediate.data, _h_intermediate.data, vCuts.size()*vCutMaxVecLen*sizeof(float), _stream );
}

}; // namespace popart

