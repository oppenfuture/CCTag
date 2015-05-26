#include <iostream>
#include <limits>
#include <assert.h>
#include <fstream>
#include <string.h>
#include <cuda_runtime.h>
#include "debug_macros.hpp"

#include "frame.h"

namespace popart {

using namespace std;

/*************************************************************
 * Frame
 *************************************************************/

void Frame::hostDebugDownload( )
{
    delete [] _h_debug_plane;
    delete [] _h_debug_smooth;
    delete [] _h_debug_dx;
    delete [] _h_debug_dy;
    delete [] _h_debug_mag;
    delete [] _h_debug_map;

    _h_debug_plane  = new unsigned char[ getWidth() * getHeight() ];
    _h_debug_smooth = new float[ getWidth() * getHeight() ];
    _h_debug_dx     = new int16_t[ getWidth() * getHeight() ];
    _h_debug_dy     = new int16_t[ getWidth() * getHeight() ];
    _h_debug_mag    = new uint32_t[ getWidth() * getHeight() ];
    _h_debug_map    = new unsigned char[ getWidth() * getHeight() ];

    POP_SYNC_CHK;

#if 0
    cerr << "Trigger download of debug plane: "
         << "(" << _d_plane.cols << "," << _d_plane.rows << ") pitch " << _d_plane.step
         << " to "
         << "(" << getWidth() << "," << getHeight() << ")" << endl;
#endif
    POP_CUDA_MEMCPY_2D_ASYNC( _h_debug_plane, getWidth(),
                              _d_plane.data, _d_plane.step,
                              _d_plane.cols,
                              _d_plane.rows,
                              cudaMemcpyDeviceToHost, _stream );
#if 0
    cerr << "Trigger download of Gaussian debug plane: "
         << "(" << _d_smooth.cols << "," << _d_smooth.rows << ") pitch " << _d_smooth.step
         << " to "
         << "(" << getWidth() << "," << getHeight() << ")" << endl;
#endif
    POP_CUDA_MEMCPY_2D_ASYNC( _h_debug_smooth, getWidth() * sizeof(float),
                              _d_smooth.data, _d_smooth.step,
                              _d_smooth.cols * sizeof(float),
                              _d_smooth.rows,
                              cudaMemcpyDeviceToHost, _stream );
    POP_CUDA_MEMCPY_2D_ASYNC( _h_debug_dx, getWidth() * sizeof(int16_t),
                              _d_dx.data, _d_dx.step,
                              _d_dx.cols * sizeof(int16_t),
                              _d_dx.rows,
                              cudaMemcpyDeviceToHost, _stream );
    POP_CUDA_MEMCPY_2D_ASYNC( _h_debug_dy, getWidth() * sizeof(int16_t),
                              _d_dy.data, _d_dy.step,
                              _d_dy.cols * sizeof(int16_t),
                              _d_dy.rows,
                              cudaMemcpyDeviceToHost, _stream );
    POP_CUDA_MEMCPY_2D_ASYNC( _h_debug_mag, getWidth() * sizeof(uint32_t),
                              _d_mag.data, _d_mag.step,
                              _d_mag.cols * sizeof(uint32_t),
                              _d_mag.rows,
                              cudaMemcpyDeviceToHost, _stream );
    POP_CUDA_MEMCPY_2D_ASYNC( _h_debug_map, getWidth() * sizeof(uint8_t),
                              _d_map.data, _d_map.step,
                              _d_map.cols * sizeof(uint8_t),
                              _d_map.rows,
                              cudaMemcpyDeviceToHost, _stream );
}

#if 0
__host__
static void testme( cv::cuda::PtrStepSzf src )
{
    size_t non_null_ct = 0;
    float minval = 1000.0f;
    float maxval = -1000.0f;
    for( size_t i=0; i<src.rows; i++ )
        for( size_t j=0; j<src.cols; j++ ) {
            float f = src.ptr(i)[j];
            if( f != 0.0f )
                non_null_ct++;
            minval = min( minval, f );
            maxval = max( maxval, f );
        }
    printf("testme: There are %lu non-null values in the Gaussian end result (min %f, max %f)\n", (unsigned long)non_null_ct, minval, maxval );
}
#endif

void Frame::writeDebugPlane1( const char* filename, const cv::cuda::PtrStepSzb& plane )
{
    cerr << "Enter " << __FUNCTION__ << endl;
    assert( plane.data );

    ofstream of( filename );
    of << "P5" << endl
       << plane.cols << " " << plane.rows << endl
       << "255" << endl;
    of.write( (char*)plane.data, plane.cols * plane.rows );
    cerr << "Leave " << __FUNCTION__ << endl;
}

template<class T>
__host__
void Frame::writeDebugPlane( const char* filename, const cv::cuda::PtrStepSz<T>& plane )
{
    cerr << "Enter " << __FUNCTION__ << endl;
    cerr << "    filename: " << filename << endl;

    ofstream of( filename );
    of << "P5" << endl
       << plane.cols << " " << plane.rows << endl
       << "255" << endl;

    // T minval = 1000;  // std::numeric_limits<float>::max();
    // T maxval = -1000; // std::numeric_limits<float>::min();
    T minval = std::numeric_limits<T>::max();
    T maxval = std::numeric_limits<T>::min();
    // for( uint32_t i=0; i<plane.rows*plane.cols; i++ ) {
    for( size_t i=0; i<plane.rows; i++ ) {
        for( size_t j=0; j<plane.cols; j++ ) {
            T f = plane.ptr(i)[j];
            // float f = plane.data[i];
            minval = min( minval, f );
            maxval = max( maxval, f );
        }
    }
    cerr << "    step size is " << plane.step << endl;
    cerr << "    found minimum value " << minval << endl;
    cerr << "    found maximum value " << maxval << endl;

    // testme( plane );

    maxval = 255.0 / ( maxval - minval );
    for( uint32_t i=0; i<plane.rows*plane.cols; i++ ) {
        T f = plane.data[i];
        f = ( f - minval ) * maxval;
        unsigned char uc = (unsigned char)f;
        of << uc;
    }

    cerr << "Leave " << __FUNCTION__ << endl;
}

void Frame::hostDebugCompare( unsigned char* pix )
{
    bool found_mistake = false;
    size_t mistake_ct = 0;

    for( int h=0; h<_d_plane.rows; h++ ) {
        for( int w=0; w<_d_plane.cols; w++ ) {
            if( pix[h*_d_plane.cols+w] != _h_debug_plane[h*_d_plane.cols+w] ) {
                mistake_ct++;
                if( found_mistake == false ) {
                    found_mistake = true;
                    cerr << "Found first error at (" << w << "," << h << "): "
                         << "orig " << pix[h*_d_plane.cols+w]
                         << "copy " << _h_debug_plane[h*_d_plane.cols+w]
                         << endl;
                }
            }
        }
    }
    if( found_mistake ) {
        cerr << "Total errors: " << mistake_ct << endl;
    } else {
        cerr << "Found no difference between original and re-downloaded frame" << endl;
    }
}

void Frame::writeHostDebugPlane( string filename )
{
    string s = filename + ".pgm";
    cv::cuda::PtrStepSzb b( getHeight(),
                            getWidth(),
                            _h_debug_plane,
                            getWidth() );
    writeDebugPlane1( s.c_str(), b );

    s = filename + "-gauss.pgm";
    cv::cuda::PtrStepSzf smooth( getHeight(),
                                 getWidth(),
                                 _h_debug_smooth,
                                 getWidth()*sizeof(float) );
    writeDebugPlane( s.c_str(), smooth );

    s = filename + "-dx.pgm";
    cv::cuda::PtrStepSz16s dx( getHeight(),
                               getWidth(),
                               _h_debug_dx,
                               getWidth()*sizeof(int16_t) );
    writeDebugPlane( s.c_str(), dx );

    s = filename + "-dy.pgm";
    cv::cuda::PtrStepSz16s dy( getHeight(),
                               getWidth(),
                               _h_debug_dy,
                               getWidth()*sizeof(int16_t) );
    writeDebugPlane( s.c_str(), dy );

    s = filename + "-mag.pgm";
    cv::cuda::PtrStepSz32u mag( getHeight(),
                                getWidth(),
                                _h_debug_mag,
                                getWidth()*sizeof(uint32_t) );
    writeDebugPlane( s.c_str(), mag );

    s = filename + "-map.pgm";
    cv::cuda::PtrStepSzb   map( getHeight(),
                                getWidth(),
                                _h_debug_map,
                                getWidth()*sizeof(uint8_t) );
    writeDebugPlane( s.c_str(), map );
}

}; // namespace popart

