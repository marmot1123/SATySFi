
open LengthInterface
open HorzBox

type t

val create_empty_pdf : string -> t

type page

val write_page : page -> page_parts_scheme_func -> t -> t

val write_to_file : t -> unit

val page_of_evaled_vert_box_list : page_size -> page_break_info -> page_content_scheme -> evaled_vert_box list -> page
