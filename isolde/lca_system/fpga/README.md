
# Initial setup
in folder 'isolde/lca_system': 

```sh
. ./eth.sh 
make rtl-update
```
# Vivado lint
in folder 'isolde/lca_system/fpga':  
```sh
 make cfg-zcu104
 make clean
 make
 ```