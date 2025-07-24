// Copyleft 2025 ISOLDE
//

module isolde_hci_monitor #(
    parameter int unsigned DW = hci_package::DEFAULT_DW,  /// Data Width
    parameter int unsigned AW = hci_package::DEFAULT_AW,  /// Address Width
    parameter string NAME = "isolde_hci_monitor",
    parameter int ID = 0  // ID of the HCI monitor (default 0)
) (
    input logic clk_i,
    input logic rst_ni,

    hci_core_intf.monitor hci_core
);
typedef enum  { idle, req_r,req_w,gnt, r_ready } hci_mon_state_t;
hci_mon_state_t hci_mon_state, hci_mon_state_next;
  // request phase payload
  logic [AW-1:0] add;
  logic [DW-1:0] data;
  logic wen;  // write enable negative
  logic req;
 

always_comb begin
  hci_mon_state_next = idle;
  if (hci_core.req) begin
    hci_mon_state_next = hci_core.wen ? req_r: req_w;
  end
end

  always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) hci_mon_state <= idle;
      else hci_mon_state <= hci_mon_state_next; 
  end

 always_ff @(posedge clk_i or negedge rst_ni) begin
  case (hci_mon_state_next)
   req_r,req_w:  begin
          wen <= hci_core.wen;
           add <=  hci_core.add;
           data <= hci_core.data;
           end
    default:begin
           wen<=0;
           add<='0;
           data<='0; end
  endcase
 end


  always_ff @(posedge clk_i or negedge rst_ni) begin
    // Monitor logic to track HCI core activity
    // This is a placeholder for actual monitoring logic
    if (hci_core.r_valid  ) begin
      case(hci_mon_state)
        req_w: begin
           $fwrite(fh_csv, "%t, %d, 0x%h, 0x%h\n", $time, wen, add, data);
           end 
        req_r: begin
           $fwrite(fh_csv, "%t, %d, 0x%h, 0x%h\n", $time, wen, add, hci_core.r_data);
           end
      endcase
    end
  end

  int    fh_csv;  //filehandle
  string log_filename;

  initial begin
    log_filename = $sformatf("%s_%0d.csv", NAME, ID);
    fh_csv = $fopen(log_filename, "w");
    if (fh_csv == 0) begin
      $display("ERROR: Could not open %s for writing", log_filename);
      $finish;
    end else begin
      $fwrite(fh_csv, "time,wen,addr,data\n");
    end
  end


  // Close the CSV output file at the end of simulation to ensure all data is written properly.
  final begin
    if (fh_csv != 0) begin
      $fclose(fh_csv);
    end
  end
endmodule
