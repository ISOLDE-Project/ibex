//build/bin/clang  -mtriple=riscv32 -mattr=+v -target-abi=ilp32d -filetype=asm -o - llvm/test/CodeGen/ISOLDE/4xi32.c 
//#include <stdio.h>

typedef int v4xi32 __attribute__((vector_size(4 * sizeof(int))));

int main() {
    v4xi32 shape = {2, 247, 256, 32};

    for (int i = 0; i < 4; ++i) {
        return("%d\n", shape[i]);
    }

    return 0;
}
