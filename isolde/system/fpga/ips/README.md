# How to create initial setup
- duplicate an existing folder  
    in *Makefile* adjust the project name, i.e. **PROJECT		        :=  <xilinx_*> **
- in the new folder run **make all**
- open the newly created project in Vivado  
    delete the old IP  
    Go to IP Catalog( left pannel)  
    Set Component Name to **<PROJECT>**  
    Configure the IP 
    in Vivado, Tcl Console, run 
    ```tcl
     cd <project_folder>/tcl
     source ./export_ip.tcl
     ```
- close the project in Vivado
- tcl/<PROJECT>-ip.tcl contains the tcl script to regenerate the ip
- modify the *CREATE IP* section in tcl/run.tcl to match tcl/<PROJECT>-ip.tcl 
- 
    ```sh
    make clean
    make all
    ```
That's all folks! :)