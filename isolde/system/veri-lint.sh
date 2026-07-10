TEST=cohen128b_test
export ROOT_DIR=$(git rev-parse --show-toplevel)
rm -f $ROOT_DIR/isolde/system/isolde_exec_block.log
make ENABLE_SPM=1 TEST=$TEST  veri-clean veri-lint 2>&1 | tee -a $ROOT_DIR/isolde/system/veri-lint.log
echo "Output is here: '$ROOT_DIR/isolde/system/veri-lint.log' "
