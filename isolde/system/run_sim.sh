
export ROOT_DIR=$(git rev-parse --show-toplevel)
rm -f $ROOT_DIR/isolde/system/isolde_exec_block.log
make TEST=conv2d_test test-clean test-build veri-run
echo "Output is here: '$ROOT_DIR/isolde/system/isolde_exec_block.log' "
cat isolde_exec_block.log