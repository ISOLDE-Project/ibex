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
  // request phase payload
  logic [AW-1:0] add;
  logic [DW-1:0] data;
  logic wen;  // write enable negative
  logic req;
  logic r_valid;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    req <= hci_core.req;  // Capture the request signal from the HCI core
    if (hci_core.req) begin
      // Capture the request phase payload when the request is granted
      wen  <= ~hci_core.wen;  // Invert write enable for monitor
      add  <= hci_core.add;
      data <= hci_core.data;
    end
    r_valid <= hci_core.r_valid;  // Capture the read valid signal
    // wen  <= hci_core.wen;  // Invert write enable for monitor

  end



  always_ff @(posedge clk_i or negedge rst_ni) begin
    // Monitor logic to track HCI core activity
    // This is a placeholder for actual monitoring logic
    if (r_valid & req & hci_core.gnt) begin
      if (wen) begin
        $fwrite(fh_csv, "%t, %d, 0x%h, 0x%h\n", $time, wen, add, data);
      end else begin
        $fwrite(fh_csv, "%t, %d, 0x%h, 0x%h\n", $time, wen, add, hci_core.r_data);
      end
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
