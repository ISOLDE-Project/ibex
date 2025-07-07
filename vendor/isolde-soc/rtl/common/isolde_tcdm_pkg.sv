// Copyleft ISOLDE 2025

/* 
 *
 * 
 */

package isolde_tcdm_pkg;
  localparam int unsigned TCDM_DW = 32;  // Data width of TCDM interface
  localparam int unsigned TCDM_AW = 32;  // Address width of TCDM interface
  localparam int unsigned TCDM_BEW = 4;  // Byte enable width of TCDM interface
  localparam int unsigned ISOLDE_TCDM_REQ_SIZE = 1+1+TCDM_BEW+TCDM_AW+TCDM_DW;  // Size of TCDM request
  localparam int unsigned ISOLDE_TCDM_RSP_SIZE = 1 + 1 + 1 + TCDM_DW;  // Size of TCDM response

  typedef struct packed {
    logic                req;
    logic                we;
    logic [TCDM_BEW-1:0] be;
    logic [TCDM_AW-1:0]  addr;
    logic [TCDM_DW-1:0]  data;
  } req_t;

  // RESPONSE CHANNEL
  typedef struct packed {
    logic               gnt;
    logic               valid;
    logic               err;
    logic [TCDM_DW-1:0] data;
  } rsp_t;

  typedef logic [ISOLDE_TCDM_REQ_SIZE-1:0] opaq_req_t;
  typedef logic [ISOLDE_TCDM_RSP_SIZE-1:0] opaq_rsp_t;

  function automatic opaq_req_t to_opaq_req(req_t req);
    return opaq_req_t'(req);  // Bit-cast
  endfunction

  function automatic opaq_rsp_t to_opaq_rsp(rsp_t rsp);
    return opaq_rsp_t'(rsp);
  endfunction

  //
  function automatic req_t from_opaq_req(opaq_req_t opaq);
    return req_t'(opaq);
  endfunction

  function automatic rsp_t from_opaq_rsp(opaq_rsp_t opaq);
    return rsp_t'(opaq);
  endfunction

endpackage
