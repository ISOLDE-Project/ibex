rm -rf app-images
. ./eth.sh 
make -f Makefile.apps apps-build APPS="\
complex_gemm                \
hello_test                  \
dhrystone21                 \
isolde_banner               \
omp_test                    \
onnx_complex_gemm           \
onnx_radar_attention        \
onnx_tiling_gemm            \
radar_attention             \
radar_beamforming           \
"
make TEST=coremark TEST_CFLAGS="-DITERATIONS=2000" test-clean test-build
cp -v sw/bin/coremark-*.*hex  app-images/
. ./torch.sh 
make TEST=onnx_radar_attention cases  
. ./eth.sh 
echo "Build demo apps done"
