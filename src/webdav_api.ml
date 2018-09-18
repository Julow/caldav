module Xml = Webdav_xml
open Webdav_config
type tree = Xml.tree
type content_type = string

module type S =
sig
  type state

  val mkcol : state -> config -> path:string -> user:string -> Cohttp.Code.meth -> Ptime.t -> data:string ->
    (unit, [ `Bad_request | `Conflict | `Forbidden of string ]) result Lwt.t

  val propfind : state -> config -> path:string -> user:string -> depth:string option -> data:string -> 
    (string, [> `Bad_request | `Forbidden of string | `Property_not_found ]) result Lwt.t

  val proppatch : state -> config -> path:string -> user:string -> data:string -> 
    (string, [> `Bad_request ]) result Lwt.t

  val report : state -> config -> path:string -> user:string -> data:string -> 
    (string, [> `Bad_request ]) result Lwt.t

  val write_component : state -> config -> path:string -> user:string -> Ptime.t -> content_type:content_type -> data:string ->
    (string, [> `Bad_request | `Conflict | `Forbidden | `Internal_server_error ]) result Lwt.t

  val delete : state -> path:string -> Ptime.t -> bool Lwt.t

  val read : state -> path:string -> is_mozilla:bool -> (string * content_type, [> `Not_found ]) result Lwt.t

  val access_granted_for_acl : state -> config -> Cohttp.Code.meth -> path:string -> user:string -> bool Lwt.t

  val last_modified : state -> path:string -> string option Lwt.t

  val compute_etag : state -> path:string -> string option Lwt.t

  val verify_auth_header : state -> Webdav_config.config -> string -> (string, string) result Lwt.t

  val make_user : ?props:(Webdav_xml.fqname * Properties.property) list -> state -> config -> string -> string -> unit Lwt.t
  val make_group : state -> config -> string -> string -> string list -> unit Lwt.t
  val initialize_fs : state -> config -> unit Lwt.t
end

module Make(Fs: Webdav_fs.S) = struct
  open Lwt.Infix

  type state = Fs.t

  let compute_etag str = Digest.to_hex @@ Digest.string str

  let is_calendar fs file =
    Fs.get_property_map fs file >|= fun map ->
    (* TODO access check missing *)
    match Properties.unsafe_find (Xml.dav_ns, "resourcetype") map with
    | None -> false
    | Some (_, trees) ->
       let calendar_node = function
       | Xml.Node (ns, "calendar", _, _) when ns = Xml.caldav_ns -> true
       | _ -> false in
       List.exists calendar_node trees
 
  let properties_for_current_user fs config user =
    let user_path = `Dir [ config.principals ; user ] in
    Fs.get_property_map fs user_path

  let acl fs config user path =
    properties_for_current_user fs config user >>= fun auth_user_props ->
    Fs.get_property_map fs path >|= fun resource_props ->
    if not (Privileges.is_met ~requirement:`Read_acl @@
            Properties.privileges ~auth_user_props resource_props)
    then Error `Forbidden
    (* we check above that Read_acl is allowed, TODO express with find_many *)
    else match Properties.unsafe_find (Xml.dav_ns, "acl") resource_props with
      | None -> Ok []
      | Some (_, aces) ->
        let aces' = List.map Xml.xml_to_ace aces in
        Ok (List.fold_left (fun acc -> function Ok ace -> ace :: acc | _ -> acc) [] aces')

  let parse_calendar ~path data =
    match Icalendar.parse data with
    | Error e ->
      Printf.printf "error %s while parsing calendar\n" e ;
      Error `Bad_request
    | Ok cal ->
      let ics = Icalendar.to_ics cal in
      let file = Fs.file_from_string path in
      Ok (ics, file)

  let write_if_parent_exists fs config (file : Webdav_fs.file) timestamp content_type user ics =
    let file' = (file :> Webdav_fs.file_or_dir) in
    let parent = Fs.parent file' in
    let parent' = (parent :> Webdav_fs.file_or_dir) in
    Fs.dir_exists fs parent >>= function
    | false ->
      Printf.printf "parent directory of %s does not exist\n" (Fs.to_string file') ;
      Lwt.return (Error `Conflict)
    | true ->
      acl fs config user parent' >>= function
      | Error e -> Lwt.return @@ Error `Forbidden
      | Ok acl -> 
        is_calendar fs parent' >>= function
        | false -> Lwt.return @@ Error `Bad_request
        | true ->
          let etag = compute_etag ics in
          let props = Properties.create ~content_type ~etag
              acl timestamp (String.length ics) (Fs.to_string file')
          in
          Fs.write fs file (Cstruct.of_string ics) props >|= function
          | Error e -> Error `Internal_server_error
          | Ok () -> Ok etag

  let write_component fs config ~path ~user timestamp ~content_type ~data =
    match parse_calendar ~path data with
    | Error e -> Lwt.return @@ Error e
    | Ok (ics, file) -> write_if_parent_exists fs config file timestamp content_type user ics

  (* out: ( name * typ * last_modified ) list - non-recursive *)
  let list_dir fs (`Dir dir) =
    let list_file f_or_d =
      (* maybe implement a Fs.get_property? *)
      Fs.get_property_map fs f_or_d >|= fun m ->
      (* restore last modified from properties as a workaround because the file system does not provide it *)
      let last_modified = match Properties.unsafe_find (Xml.dav_ns, "getlastmodified") m with
        | Some (_, [ Xml.Pcdata lm ]) -> lm
        | _ -> assert false
      in
      let is_dir = match f_or_d with
        | `File _ -> false | `Dir _ -> true
      in
      (Fs.to_string f_or_d, is_dir, last_modified)
    in
    Fs.listdir fs (`Dir dir) >>= function
    | Error e -> assert false
    | Ok files -> Lwt_list.map_p list_file files

  let directory_as_html fs (`Dir dir) =
    list_dir fs (`Dir dir) >|= fun files ->
    let print_file (file, is_dir, last_modified) =
      Printf.sprintf "<tr><td><a href=\"%s\">%s</a></td><td>%s</td><td>%s</td></tr>"
        file file (if is_dir then "directory" else "text/calendar") last_modified in
    let data = String.concat "\n" (List.map print_file files) in
    (data, "text/html")
  
  let directory_etag fs (`Dir dir) =
    directory_as_html fs (`Dir dir) >|= fun (data, ct) ->
    compute_etag data
  
  let directory_as_ics fs (`Dir dir) =
    let calendar_components = function
      | `Dir d ->
        Printf.printf "calendar components of directory %s\n%!" (Fs.to_string (`Dir d)) ;
        Lwt.return []
        (* assert false (* CalDAV forbids nested calendars *) *)
      | `File f ->
        Fs.read fs (`File f) >|= function
        | Error _ -> Printf.printf "error while reading file!\n" ; []
        | Ok (data, _props) ->
          match Icalendar.parse (Cstruct.to_string data) with
          | Ok calendar -> snd calendar
          | Error e -> Printf.printf "error %s while parsing ics\n" e ; []
    in
    Fs.listdir fs (`Dir dir) >>= function
    | Error _ -> assert false (* previously checked that directory exists *)
    | Ok files ->
      (* TODO: hardcoded calprops, put them elsewhere *)
      Fs.get_property_map fs (`Dir dir) >>= fun props ->
      let empty = Icalendar.Params.empty in
      let name =
        (* instantiate the calendar name from the displayname property *)
        match Properties.unsafe_find (Xml.dav_ns, "displayname") props with
        | Some (_, [ Xml.Pcdata name ]) -> [ `Xprop (("WR", "CALNAME"), empty, name) ]
        | _ -> []
      in
      let calprops = [
        `Prodid (empty, "-//ROBUR.IO//EN") ;
        `Version (empty, "2.0")
      ] @ name in
      Lwt_list.map_p calendar_components files >|= fun components ->
      let data = Icalendar.to_ics (calprops, List.flatten components) in
      (data, "text/calendar")

  let read fs ~path ~is_mozilla =
    Fs.from_string fs path >>= function
    | Error _ -> Lwt.return @@ Error `Not_found
    | Ok (`Dir dir) ->
      (if is_mozilla then
        directory_as_html fs (`Dir dir)
      else
        (* TODO: check wheter CalDAV:calendar property is set as resourcetype!
           otherwise: standard WebDAV directory listing *)
        directory_as_ics fs (`Dir dir)) >|= fun res ->
      Ok res 
    | Ok (`File f) ->
      Fs.read fs (`File f) >|= function
      | Error _ -> Error `Not_found
      | Ok (data, props) ->
      (* this property only needs read, which has been checked on the resource already *)
      let ct = match Properties.unsafe_find (Xml.dav_ns, "getcontenttype") props with
        | Some (_, [ Xml.Pcdata ct ]) -> ct
        | _ -> "text/calendar" in
      Ok (ct, Cstruct.to_string data)


  let delete fs ~path now =
    Fs.from_string fs path >>= function
    | Error _ -> Lwt.return false
    | Ok f_or_d -> 
      Fs.destroy fs f_or_d >>= fun res ->
      let now = Ptime.to_rfc3339 now in
      (* TODO for a collection/directory, the last modified is defined as maximum last modified of
         all present files or directories.  If the directory is empty, its creationdate is used.
         if we delete the last file in a directory, we need to update the getlastmodified property *)
      let rec update_parent f_or_d =
        let (`Dir parent) = Fs.parent f_or_d in
        Fs.get_property_map fs (`Dir parent) >>= fun map ->
        let map' = Properties.unsafe_add (Xml.dav_ns, "getlastmodified") ([], [ Xml.pcdata now ]) map in
        Fs.write_property_map fs (`Dir parent) map' >>= function
        | Error e -> assert false
        | Ok () -> match parent with
          | [] -> Lwt.return_unit
          | dir -> update_parent (`Dir dir)
      in
      update_parent f_or_d >|= fun () ->
      true

  let statuscode_to_string res =
    Format.sprintf "%s %s"
      (Cohttp.Code.string_of_version `HTTP_1_1)
      (Cohttp.Code.string_of_status res)

  let propstat_node (code, props) =
    Xml.dav_node "propstat" [
      Xml.dav_node "prop" props ;
      Xml.dav_node "status" [ Xml.pcdata (statuscode_to_string code) ] ]

  let parse_depth = function
    | None -> Ok `Infinity
    | Some "0" -> Ok `Zero
    | Some "1" -> Ok `One
    | Some "infinity" -> Ok `Infinity
    | _ -> Error `Bad_request

  let uri_string host f_or_d =
    Uri.to_string @@ Uri.with_path host (Fs.to_string f_or_d)

  let property_selector fs host propfind_request auth_user_props f_or_d =
    Fs.get_property_map fs f_or_d >|= fun map ->
    if map = Properties.empty
    then `Not_found
    else
      (* results for props, grouped by code *)
      let propstats = match propfind_request with
        | `Propname -> [`OK, Properties.names map]
        | `All_prop includes -> [`OK, Properties.all map] (* TODO: finish this *)
        | `Props ps -> Properties.find_many ~auth_user_props ps map
      in
      let ps = List.map propstat_node propstats in
      let selected_properties =
        Xml.dav_node "response"
          (Xml.dav_node "href" [ Xml.Pcdata (uri_string host f_or_d) ] :: ps)
      in
      `Single_response selected_properties

  let multistatus nodes = Xml.dav_node "multistatus" nodes

  let error_xml element = Xml.dav_node "error" [ Xml.dav_node element [] ]

  let propfind fs f_or_d host req auth_user_props depth =
    let process_files fs host dir req els =
      Lwt_list.map_s (property_selector fs host req auth_user_props) (dir :: els) >|= fun answers ->
      (* answers : [ `Not_found | `Single_response of Tyxml.Xml.node ] list *)
      let nodes = List.fold_left (fun acc element ->
          match element with
          | `Not_found -> acc
          | `Single_response node -> node :: acc) [] answers
      in
      Ok (multistatus nodes)
    in
    match depth, f_or_d with
    | `Infinity, _ ->
      let data = error_xml "propfind-finite-depth" in
      Lwt.return (Error (`Forbidden (Xml.tree_to_string data)))
    | `Zero, _
    | _, `File _ ->
      begin
        property_selector fs host req auth_user_props f_or_d >|= function
        | `Not_found -> Error `Property_not_found
        | `Single_response t -> Ok (multistatus [t])
      end
    | `One, `Dir data ->
      Fs.listdir fs (`Dir data) >>= function
      | Error _ -> assert false
      | Ok els -> process_files fs host (`Dir data) req els

  let propfind fs config ~path ~user ~depth ~data =
    Fs.from_string fs path >>= function
    | Error _ -> Lwt.return @@ Error `Bad_request
    | Ok f_or_d ->
      properties_for_current_user fs config user >>= fun auth_user_props ->
      match Xml.string_to_tree data with
      | None -> Lwt.return @@ Error `Bad_request
      | Some req_tree -> match parse_depth depth with
        | Error `Bad_request -> Lwt.return (Error `Bad_request)
        | Ok depth -> match Xml.parse_propfind_xml req_tree with
          | Error _ -> Lwt.return (Error `Property_not_found)
          | Ok req -> propfind fs f_or_d config.host req auth_user_props depth >|= function
            | Error e -> Error e
            | Ok resp_tree -> Ok (Xml.tree_to_string resp_tree)

  let update_properties fs f_or_d updates =
    Fs.get_property_map fs f_or_d >>= fun map ->
    let map', xs = Properties.patch map updates in
    let propstats = List.map propstat_node xs in
    (match map' with
     | None -> Lwt.return (Ok ())
     | Some m -> Fs.write_property_map fs f_or_d m) >|= function
    | Error e -> Error e
    | Ok () -> Ok propstats

  let proppatch fs config ~path ~user ~data =
    Fs.from_string fs path >>= function
    | Error _ -> Lwt.return @@ Error `Bad_request
    | Ok f_or_d ->
      properties_for_current_user fs config user >>= fun auth_user_props ->
      match Xml.string_to_tree data with
      | None -> Lwt.return @@ Error `Bad_request
      | Some req_tree -> match Xml.parse_propupdate_xml req_tree with
        | Error _ -> Lwt.return @@ Error `Bad_request
        | Ok updates ->
          update_properties fs f_or_d updates >|= function
          | Error _      -> Error `Bad_request
          | Ok propstats ->
            let nodes =
              Xml.dav_node "response"
                (Xml.dav_node "href" [ Xml.Pcdata (uri_string config.host f_or_d) ] :: propstats)
            in
            let resp = multistatus [ nodes ] in
            Ok (Xml.tree_to_string resp)

  let data_to_proppatch = function
    | None -> Ok []
    | Some data' -> match Xml.parse_mkcol_xml data' with
      | Error _ -> Error `Bad_request
      | Ok set_props -> Ok set_props

  let calendar_to_collection data =
    if data = "" then Ok "" else
    match Xml.string_to_tree data with
    | Some (Xml.Node (ns, "mkcalendar", a, c)) when ns = Xml.caldav_ns -> Ok (Xml.tyxml_to_body @@ Xml.tree_to_tyxml @@ Xml.node ~ns:Xml.dav_ns ~a "mkcol" c)
    | _ -> Error `Bad_request

  (* assumption: path is a relative path! *)
  let mkcol fs config ~path ~user http_verb now ~data =
    let dir = Fs.dir_from_string path in
    let parent = Fs.parent (dir :> Webdav_fs.file_or_dir) in
    let parent' = (parent :> Webdav_fs.file_or_dir) in
    Fs.dir_exists fs parent >>= function
    | false -> Lwt.return @@ Error `Conflict
    | true -> 
      let resource_is_calendar, resourcetype, collection_data = match http_verb with
      | `Other "MKCALENDAR" -> true, [Xml.node ~ns:Xml.caldav_ns "calendar" []], calendar_to_collection data
      | `Other "MKCOL" -> false, [], Ok data
      | _ -> assert false in
      match collection_data with
      | Error _ -> Lwt.return @@ Error `Conflict
      | Ok collection -> match Xml.string_to_tree collection with
        | None when collection <> "" -> Lwt.return @@ Error `Conflict
        | collection_tree -> match data_to_proppatch collection_tree with
          | Error e -> Lwt.return @@ Error e
          | Ok set_props ->
            is_calendar fs parent' >>= fun parent_is_calendar ->
            if resource_is_calendar && parent_is_calendar
            then Lwt.return @@ Error `Conflict
            else
              acl fs config user parent' >>= function
              | Error `Forbidden -> Lwt.return @@ Error (`Forbidden "TODO") 
              | Ok parent_acl ->
                let col_props = Properties.create_dir ~resourcetype parent_acl now (Fs.to_string (dir :> Webdav_fs.file_or_dir)) in
                match Properties.patch ~is_mkcol:true col_props set_props with
                | None, errs ->
                  let propstats = List.map propstat_node errs in
                  let xml = Xml.dav_node "mkcol-response" propstats in
                  Printf.printf "forbidden from data_to_props!\n" ;
                  let res = Xml.tree_to_string xml in
                  Lwt.return @@ Error (`Forbidden res)
                | Some map, _ ->
                  Fs.mkdir fs dir map >|= function
                  | Error _ -> Error `Conflict
                  | Ok () -> Ok ()

  let check_in_bounds p s e = true
  let apply_to_params pfs p = true
  let text_matches s c n p = true

  let apply_to_props props =
    let key p = Icalendar.Writer.cal_prop_to_ics_key p in
    function
    | (name, `Is_defined) ->
      List.exists (String.equal name) (List.map key props)
    | (name, `Is_not_defined) ->
      not (List.exists (String.equal name) (List.map key props))
    | (name, `Range ((s, e), pfs)) ->
      let property = List.find_opt (fun p -> String.equal name (key p)) props in
      (match property with
      | None -> false
      | Some p -> check_in_bounds p s e && apply_to_params pfs p)
    | (name, `Text ((substring, collate, negate), pfs)) ->
      let property = List.find_opt (fun p -> String.equal name (key p)) props in
      (match property with
      | None -> false
      | Some p -> text_matches substring collate negate p && apply_to_params pfs p)

  let get_time_properties props =
    let dtstart = match List.find_opt (function `Dtstart _ -> true | _ -> false) props with
    | None -> None
    | Some (`Dtstart (_, startdate)) -> Some startdate
    | _ -> assert false
    in
    let duration = match List.find_opt (function `Duration _ -> true | _ -> false) props with
    | None -> None
    | Some (`Duration (_, s)) -> Some s
    | _ -> assert false
    in (dtstart, duration)

  let add_span ts span = match Ptime.add_span ts span with
    | None -> assert false
    | Some ts' -> ts'

  (*
        +---------------------------------------------------------------+
        | VEVENT has the DTEND property?                                |
        |   +-----------------------------------------------------------+
        |   | VEVENT has the DURATION property?                         |
        |   |   +-------------------------------------------------------+
        |   |   | DURATION property value is greater than 0 seconds?    |
        |   |   |   +---------------------------------------------------+
        |   |   |   | DTSTART property is a DATE-TIME value?            |
        |   |   |   |   +-----------------------------------------------+
        |   |   |   |   | Condition to evaluate                         |
        +---+---+---+---+-----------------------------------------------+
        | Y | N | N | * | (start <  DTEND AND end > DTSTART)            |
        +---+---+---+---+-----------------------------------------------+
        | N | Y | Y | * | (start <  DTSTART+DURATION AND end > DTSTART) |
        |   |   +---+---+-----------------------------------------------+
        |   |   | N | * | (start <= DTSTART AND end > DTSTART)          |
        +---+---+---+---+-----------------------------------------------+
        | N | N | N | Y | (start <= DTSTART AND end > DTSTART)          |
        +---+---+---+---+-----------------------------------------------+
        | N | N | N | N | (start <  DTSTART+P1D AND end > DTSTART)      |
        +---+---+---+---+-----------------------------------------------+
  *)

  let date_or_datetime_to_utc_ptime timezones = function
    | `Datetime (`Utc dtstart) -> dtstart, true
    | `Datetime (`Local dtstart) -> dtstart, true
    | `Datetime (`With_tzid (dtstart, tzid)) ->
       (match Icalendar.normalize_timezone dtstart tzid timezones with
       | None -> dtstart, true
       | Some ts' -> ts', true)
    | `Date start -> match Ptime.of_date_time (start, ((0, 0, 0), 0)) with
      | None -> assert false
      | Some dtstart -> dtstart, false

  (* start and end_ mark the range,
     dtstart and dtend and duration mark the component, e.g. event *)
  let span_in_timerange range dtstart dtend duration dtstart_is_datetime =
    let (start, end_) = range in
    let duration_gt_0 = match duration with
      | None -> false
      | Some d -> Ptime.Span.compare Ptime.Span.zero d = -1
    in
    let (<) a b = Ptime.is_earlier a ~than:b
    and (>) a b = Ptime.is_later a ~than:b
    in
    let (<=) a b = a < b || Ptime.equal a b
    and (+) a b = add_span a b
    and p1d = Ptime.Span.of_int_s (24 * 60 * 60)
    in
    match dtend, duration, duration_gt_0, dtstart_is_datetime with
    | Some dtend, None, false, _    -> start < dtend && end_ > dtstart
    | None, Some duration, true, _  -> start < (dtstart + duration) && end_ > dtstart
    | None, Some duration, false, _ -> start <= dtstart && end_ > dtstart
    | None, None, false, true       -> start <= dtstart && end_ > dtstart
    | None, None, false, false      -> start < (dtstart + p1d) && end_ > dtstart
    | _                             -> assert false (* duration_gt_0 is dependent on duration *)

  let real_event_in_timerange timezones event range =
    let dtstart, dtstart_is_datetime = date_or_datetime_to_utc_ptime timezones (snd event.Icalendar.dtstart) in
    let dtend, duration = match event.Icalendar.dtend_or_duration with
      | None -> None, None
      | Some (`Duration (_, span)) -> None, Some span
      | Some (`Dtend (_, v)) -> Some (fst (date_or_datetime_to_utc_ptime timezones v)), None
    in
    span_in_timerange range dtstart dtend duration dtstart_is_datetime

  let expand_event_in_range timezones f acc range exceptions event =
    let (s, e) = range in
    let next_event = Icalendar.recur_events event in
    let rec next_r () = match next_event () with
      | None -> None
      | Some event ->
        let date_or_datetime_to_date t d = fst @@ Ptime.to_date_time @@ fst @@ date_or_datetime_to_utc_ptime t d in
        let date = date_or_datetime_to_date timezones (snd event.dtstart) in
        if List.mem date exceptions
        then next_r ()
        else Some event
    in
    let rec in_timerange acc = function
     | Some event when Ptime.is_earlier ~than:s (fst (date_or_datetime_to_utc_ptime timezones (snd event.Icalendar.dtstart))) ->
       in_timerange acc (next_r ())
     | Some event when real_event_in_timerange timezones event range ->
       let acc' = f acc event in
       in_timerange acc' (next_r ())
     | _ -> acc in
    in_timerange acc (Some event)

  let event_in_timerange timezones range exceptions event =
    let f _ _ = true in
    expand_event_in_range timezones f false range exceptions event

  (* TODO does not match freebusy table in RFC 4791 Sec 9.9 *)
  let freebusy_in_timerange range fb =
    match
      List.find_opt (function `Dtstart_utc _ -> true | _ -> false) fb,
      List.find_opt (function `Dtend_utc _ -> true | _ -> false) fb
    with
    | Some (`Dtstart_utc (_, dtstart)), Some (`Dtend_utc (_, dtend)) ->
      span_in_timerange range dtstart (Some dtend) None true
    | _ -> false

  (* TODO `Todo is missing *)
  let comp_in_timerange timezones range exceptions = function
    | `Event e -> event_in_timerange timezones range exceptions e
    | `Freebusy fb -> freebusy_in_timerange range fb
    | `Timezone _  -> true
    | _ -> false

  let date_to_ptime date = match Ptime.of_date_time (date, ((0, 0, 0), 0)) with
    | None -> assert false
    | Some t -> t

  let ptime_to_date ts = fst @@ Ptime.to_date_time ts

  let normalize_timestamp timezones = function
    | `Utc ts -> `Utc ts
    | `Local ts -> `Local ts
    | `With_tzid (ts, tzid) as d ->
      match Icalendar.normalize_timezone ts tzid timezones with
      | None -> d
      | Some ts' -> `Utc ts'

  let normalize_date_or_datetime timezones = function
    | `Date date -> `Date date
    | `Datetime dt -> `Datetime (normalize_timestamp timezones dt)

  let normalize_dates_or_datetimes timezones = function
    | `Dates ds -> `Dates ds
    | `Datetimes dts -> `Datetimes (List.map (normalize_timestamp timezones) dts)

  let normalize_dates_or_datetimes_or_periods timezones = function
    | #Icalendar.dates_or_datetimes as ds_or_dts -> normalize_dates_or_datetimes timezones ds_or_dts
    | `Periods ps -> `Periods (List.map (fun (ts, span, was_explicit) -> (normalize_timestamp timezones ts, span, was_explicit)) ps)

  let expand_event range exceptions timezones event =
    let normalize = normalize_date_or_datetime timezones in
    let normalize' = normalize_dates_or_datetimes timezones in
    let normalize'' = normalize_dates_or_datetimes_or_periods timezones in
    let add_recur_id_normalize_tz acc event' =
      let dtstart =
        let params, value = event'.Icalendar.dtstart in
        params, normalize value
      in
      let dtend_or_duration = match event'.Icalendar.dtend_or_duration with
      | None -> None
      | Some (`Duration d) -> Some (`Duration d)
      | Some (`Dtend (params, v)) -> Some (`Dtend (params, normalize v)) in
      let props = List.map (function
          | `Recur_id (params, v) -> `Recur_id (params, normalize v)
          | `Rdate (params, v) -> `Rdate (params, normalize'' v)
          | `Exdate (params, v) -> `Exdate (params, normalize' v)
          | x -> x) event'.Icalendar.props
      in
      let recur_id : Icalendar.event_prop = `Recur_id dtstart in
      let props' = match event'.Icalendar.rrule with None -> props | Some _ -> recur_id :: props in
      { event' with Icalendar.dtstart ; dtend_or_duration ; props = props' ; rrule = None } :: acc
    in
    expand_event_in_range timezones add_recur_id_normalize_tz [] range exceptions event

  let expand_comp range exceptions timezones = function
    | `Event e -> List.map (fun e -> `Event e) (expand_event range exceptions timezones e)
    (* TODO normalise other timestamps with TZID as well: DUE *)
    (*| `Todo e -> List.map (fun e -> `Todo e) (expand_todo range exceptions timezones e)*)
    | _ -> []

  (* both range and freebusy are in utc *)
  let fb_in_timerange range = function
    | `Freebusy fb ->
      let in_range (s, span, was_explicit) =
        let e = add_span s span in
        let (s_req, e_req) = range in
        let (<) a b = Ptime.is_later ~than:a b in
        let (<=) a b = a < b || Ptime.equal a b in
        (s_req <= s && e < e_req) ||
        (s_req <= e && e < e_req) ||
        (s_req <= s && s < e_req)
      in
      let prop_in_timerange = function
        | `Freebusy (_, ranges) -> List.exists in_range ranges
        | _ -> true
      in
      [ `Freebusy (List.filter prop_in_timerange fb) ]
    | _ -> []

  (* transformation step *)
  let select_calendar_data (calprop, (comps : Icalendar.component list)) (requested_data: Xml.calendar_data) =
    let (_, range, freebusy) = requested_data in
    let exceptions =
      let events =
        List.filter (function
            | `Event event -> List.exists (function `Recur_id _ -> true | _ -> false) event.Icalendar.props
            | _ -> false)
          comps
      in
      List.map (function
          | `Event event ->
            begin match event.Icalendar.dtstart with
              | (_, `Date d)          -> d
              | (_, `Datetime (`Utc d)) -> fst @@ Ptime.to_date_time d
              | (_, `Datetime (`Local d)) -> fst @@ Ptime.to_date_time d
              | (_, `Datetime (`With_tzid (d, tzid))) -> fst @@ Ptime.to_date_time d
            end
          | _ -> assert false)
        events
    in
    let timezones = List.fold_left (fun acc -> function `Timezone tz -> tz :: acc | _ -> acc) [] comps in
    let limit_rec_set comps = match range with
      | Some (`Limit_recurrence_set range) -> List.filter (comp_in_timerange timezones range exceptions) comps
      | Some (`Expand range) -> List.flatten (List.map (expand_comp range exceptions timezones) comps)
      | _ -> comps in
    let limit_freebusy_set comps = match freebusy with
      | None -> comps
      | Some (`Limit_freebusy_set range) ->
        List.flatten (List.map (fb_in_timerange range) comps)
    in
    (calprop, limit_freebusy_set @@ limit_rec_set comps)

  (*
  type comp_filter = [
    | `Is_defined (* represents empty filter in RFC *)
    | `Is_not_defined
    | `Comp_filter of timerange option * prop_filter list * component_filter list
  ]
  and component_filter = string * comp_filter
  *)

  let ts_in_range ts range =
    let (s, e) = range in
    Ptime.is_later ~than:s ts && Ptime.is_later ~than:ts e

  (* TODO deal with repeating alarms *)
  let alarm_in_timerange range alarm by_parent =
    let trigger = match alarm with
    | `Email e -> e.Icalendar.trigger
    | `Audio a -> a.Icalendar.trigger
    | `Display d -> d.Icalendar.trigger
    in
    match snd trigger with
    | `Datetime ts -> ts_in_range ts range
    | `Duration d -> (* is start or end; get duration, add to start / end *)
      let trig_rel = match Icalendar.Params.find Icalendar.Related (fst trigger) with
      | None -> `Start
      | Some x -> x
      in
      by_parent range d trig_rel


  let matches_alarm_filter by_parent alarm (comp_name, comp_filter) =
    let is_match = String.equal comp_name "VALARM" in
    match comp_filter, is_match with
    | `Is_defined, true -> true
    | `Is_not_defined, true -> false
    | `Is_defined, false -> false
    | `Is_not_defined, false -> true
    | `Comp_filter (_, _, _), false -> false
    (* no further cfs below alarm, and pfs is handled by Icalendar.to_ics (filtering on output) *)
    | `Comp_filter (tr_opt, _, _), true ->
      match tr_opt with
      | None -> true
      | Some range -> alarm_in_timerange range alarm by_parent

  let matches_comp_filter timezones component (comp_name, comp_filter) =
    let is_match =
      String.equal comp_name (Icalendar.component_to_ics_key component)
    in
    Format.printf "component matches filter %s %b (component key %s)\n" comp_name is_match (Icalendar.component_to_ics_key component) ;
    match comp_filter, is_match with
    | `Is_defined, true -> true
    | `Is_not_defined, true -> false
    | `Is_defined, false -> false
    | `Is_not_defined, false -> true
    | `Comp_filter (_, _, _), false -> false
    | `Comp_filter (tr_opt, pfs, cfs), true ->
      let matches_timerange = match tr_opt with
      | None -> true
      | Some range ->
        let exceptions = [] in (* TODO *)
        comp_in_timerange timezones range exceptions component in
      let matches_cfs = match cfs, component with
      | [], _ -> true
      | _, `Todo (props, alarms) ->
        let by_parent range d trigrel =
          let (dtstart_opt, duration) = get_time_properties props in
          match trigrel with
            | `Start ->
              (match dtstart_opt with
              | None -> assert false
              | Some dtstart ->
              let todo_start, _ = date_or_datetime_to_utc_ptime timezones dtstart in
              let alarm_start = add_span todo_start d in
              ts_in_range alarm_start range)
            | `End ->
              let due = List.find_opt (function `Due _ -> true | _ -> false) props in
              match due, dtstart_opt, duration with
              | Some (`Due (_, date_or_time)), _, _ ->
                let todo_end, _ = date_or_datetime_to_utc_ptime timezones date_or_time in
                let alarm_start = add_span todo_end d in
                ts_in_range alarm_start range
              | None, Some dtstart, Some duration ->
                let todo_start, _ = date_or_datetime_to_utc_ptime timezones dtstart in
                let todo_end = add_span todo_start duration in
                let alarm_start = add_span todo_end d in
                ts_in_range alarm_start range
              | _ -> assert false
            in

        List.exists (fun alarm -> List.exists (matches_alarm_filter by_parent alarm) cfs) alarms
      | _, `Event event ->
        let exceptions = [] in (* TODO missing! *)
        let by_parent range d trigrel =
          (* TODO may miss some events if their alarm is outside of range *)
          let events = expand_event range exceptions timezones event in
          List.exists (fun event ->
              let event_start, _ = date_or_datetime_to_utc_ptime timezones (snd event.Icalendar.dtstart) in
              match trigrel with
              | `Start ->
                let alarm_start = add_span event_start d in
                ts_in_range alarm_start range
              | `End ->
                let event_end = match event.Icalendar.dtend_or_duration with
                  | Some (`Dtend (_, dtend)) -> fst (date_or_datetime_to_utc_ptime timezones dtend)
                  | Some (`Duration (_, span)) -> add_span event_start span
                  | None -> assert false
                in
                let alarm_start = add_span event_end d in
                ts_in_range alarm_start range)
            events
        in
        List.exists (fun alarm -> List.exists (matches_alarm_filter by_parent alarm) cfs) event.Icalendar.alarms
      | _, _ -> false in
      (* TODO: treat pfs *)
      matches_timerange && matches_cfs

  let get_timezones_for_resp calendar tzids =
    let get_timezone tzid =
      let has_matching_tzid props = List.exists (function `Timezone_id (_, (_, tzid')) -> tzid = tzid' | _ -> false) props in
      List.find (function `Timezone props -> has_matching_tzid props | _ -> false ) (snd calendar) in
    List.map get_timezone @@ Astring.String.Set.elements tzids

  (* returns the entire calendar if any component matches the component filter.
     this is fine, because in caldav rfc and apple testsuite, each calendar only uses one component per file *)
  let vcalendar_matches_comp_filter filter (props, comps) =
    match filter with
    | ("VCALENDAR", `Is_defined) -> true
    | ("VCALENDAR", `Is_not_defined) -> false
    | ( _ , `Is_defined) -> false
    | ( _ , `Is_not_defined) -> true
      (*`Comp_filter of timerange option * prop_filter list * component_filter list*)
    | ("VCALENDAR", `Comp_filter (tr_opt, pfs, cfs)) ->
      let timezones = List.flatten @@ List.map (function `Timezone tz -> [tz] | _ -> []) comps in
      let matches_timerange = match tr_opt with
        | None -> true
        | Some range ->
          let exceptions = [] in (* TODO *)
          List.exists (comp_in_timerange timezones range exceptions) comps
      in
      let matches_cfs =
        (* TODO abstract *)
        List.exists (fun c -> List.exists (matches_comp_filter timezones c) cfs) comps
      in
      let matches_pfs = List.for_all (apply_to_props props) pfs in
      matches_timerange && matches_cfs && matches_pfs
    | _ -> false

  let apply_transformation (t : Xml.report_prop option) d map ~auth_user_props = match t with
    | None -> [`OK, [Xml.node ~ns:Xml.caldav_ns "calendar-data" [Xml.pcdata (Icalendar.to_ics ~cr:false d)]]]
    | Some `All_props -> [`OK, Properties.all map]
    | Some `Propname -> [`OK, Properties.names map]
    | Some `Proplist ps ->
      let props, calendar_data_transform = List.partition (function `Prop _ -> true | _ -> false) ps in
      let calendar_data_transform' = match calendar_data_transform with
        | [ `Calendar_data c ] -> Some c
        | [] -> None
        | _ -> assert false
      in
      let props' = List.map (function `Prop p -> p | _ -> assert false) props in
      let output, filter = match calendar_data_transform' with
        | None -> d, None
        | Some ((filter, _, _) as tr) -> select_calendar_data d tr, filter
      in
      let found_props = Properties.find_many ~auth_user_props props' map in
      let ok_props, rest_props = List.partition (fun (st, _) -> st = `OK) found_props in
      let ok_props' = List.flatten (List.map snd ok_props) in
      match snd output with (* kill whole calendar if comps are empty *)
      | [] -> []
      | _ ->
        let ics = Icalendar.to_ics ~cr:false ~filter output in
        let cs = [ Xml.node ~ns:Xml.caldav_ns "calendar-data" [Xml.pcdata ics] ] in
        [`OK, ok_props' @ cs ] @ rest_props

  let apply_to_vcalendar ((transform, filter): Xml.report_prop option * Xml.component_filter) data map ~auth_user_props =
    if vcalendar_matches_comp_filter filter data then
      apply_transformation transform data map ~auth_user_props
    else
      []

  let handle_calendar_query_report calendar_query fs host path ~auth_user_props =
    let report_one query = function
      | `Dir _ -> Lwt.return (Error `Bad_request)
      | `File f ->
        Fs.read fs (`File f) >|= function
        | Error _ -> Error `Bad_request
        | Ok (data, props) ->
          let privileges = Properties.privileges ~auth_user_props props in
          if not (Privileges.is_met ~requirement:`Read privileges) then
            let node = Xml.dav_node "response"
                [ Xml.dav_node "href" [ Xml.pcdata (uri_string host (`File f)) ] ;
                  Xml.dav_node "status" [ Xml.pcdata (statuscode_to_string `Forbidden) ] ]
            in
            Ok (Some node)
          else match Icalendar.parse (Cstruct.to_string data) with
            | Error e ->
              Printf.printf "Error %s while parsing %s\n" e (Cstruct.to_string data);
              Error `Bad_request
            | Ok ics ->
              match apply_to_vcalendar query ics props ~auth_user_props with
              | [] -> Ok None
              | xs ->
                let node =
                  Xml.dav_node "response"
                    (Xml.dav_node "href" [ Xml.pcdata (uri_string host (`File f)) ]
                     :: List.map propstat_node xs)
                in
                Ok (Some node)
    in
    match path with
    | `File f ->
      begin
        report_one calendar_query (`File f) >|= function
        | Ok (Some node) -> Ok (Xml.tree_to_string @@ multistatus [ node ])
        | Ok None -> Ok (Xml.tree_to_string @@ multistatus [])
        | Error e -> Error e
      end
    | `Dir d ->
      Fs.listdir fs (`Dir d) >>= function
      | Error _ -> Lwt.return (Error `Bad_request)
      | Ok files ->
        Lwt_list.map_p (report_one calendar_query) files >|= fun responses ->
        (* TODO we remove individual file errors, should we report them back?
           be consistent in respect to other HTTP verbs taking directories (e.g. propfind) *)
        let responses' = List.fold_left (fun acc -> function
            | Ok (Some r) -> r :: acc
            | Ok None -> acc
            | Error _ -> acc) [] responses in
        let resp_tree = multistatus responses' in
        Ok (Xml.tree_to_string resp_tree)

  let handle_calendar_multiget_report (transformation, filenames) fs host path ~auth_user_props =
    let report_one (filename : string) =
      Printf.printf "calendar_multiget: filename %s\n%!" filename ;
      let file = Fs.file_from_string filename in
      Fs.read fs file >|= function
      | Error _ ->
        let node =
          Xml.dav_node "response"
            [ Xml.dav_node "href" [ Xml.pcdata (uri_string host (file :> Webdav_fs.file_or_dir)) ] ;
              Xml.dav_node "status" [ Xml.pcdata (statuscode_to_string `Not_found) ] ]
        in
        Ok node
      | Ok (data, props) ->
        let privileges = Properties.privileges auth_user_props props in
        if not (Privileges.is_met ~requirement:`Read privileges) then
          let node = Xml.dav_node "response"
              [ Xml.dav_node "href" [ Xml.pcdata (uri_string host (file :> Webdav_fs.file_or_dir)) ] ;
                Xml.dav_node "status" [ Xml.pcdata (statuscode_to_string `Forbidden) ] ]
          in
          Ok node
        else
          match Icalendar.parse (Cstruct.to_string data) with
          | Error e ->
            Printf.printf "Error %s while parsing %s\n" e (Cstruct.to_string data);
            Error `Bad_request
          | Ok ics ->
            let xs = apply_transformation transformation ics props ~auth_user_props in
            let node =
              Xml.dav_node "response"
                (Xml.dav_node "href" [ Xml.pcdata (uri_string host (file :> Webdav_fs.file_or_dir)) ]
                 :: List.map propstat_node xs)
            in
            Ok node
    in
    Lwt_list.map_p report_one filenames >|= fun responses ->
    (* TODO we remove individual file parse errors, should we report them back? *)
    let responses' = List.fold_left (fun acc -> function
        | Ok r -> r :: acc
        | Error _ -> acc) [] responses in
    let resp_tree = multistatus @@ List.rev responses' in
    Ok (Xml.tree_to_string resp_tree)

  let report fs config ~path ~user ~data =
    Fs.from_string fs path >>= function
    | Error _ -> Lwt.return @@ Error `Bad_request
    | Ok f_or_d -> match Xml.string_to_tree data with
      | None -> Lwt.return @@ Error `Bad_request
      | Some req_tree ->
        properties_for_current_user fs config user >>= fun auth_user_props ->
        match Xml.parse_calendar_query_xml req_tree, Xml.parse_calendar_multiget_xml req_tree with
        | Ok calendar_query, _ -> handle_calendar_query_report calendar_query fs config.host f_or_d ~auth_user_props
        | _, Ok calendar_multiget -> handle_calendar_multiget_report calendar_multiget fs config.host f_or_d ~auth_user_props
        | Error e, Error _ -> Lwt.return (Error `Bad_request)

  let read_target_or_parent_properties fs path target_or_parent =
    (match target_or_parent with
     | `Target -> Fs.from_string fs path
     | `Parent -> Lwt.return @@ Ok (Fs.parent @@ (Fs.file_from_string path :> Webdav_fs.file_or_dir) :> Webdav_fs.file_or_dir)) >>= function
    | Error _ -> Lwt.return Properties.empty
    | Ok f_or_d -> Fs.get_property_map fs f_or_d

  let access_granted_for_acl fs config http_verb ~path ~user =
    properties_for_current_user fs config user >>= fun auth_user_props ->
    Fs.exists fs path >>= fun target_exists ->
    let requirement, target_or_parent = Privileges.required http_verb ~target_exists in
    read_target_or_parent_properties fs path target_or_parent >|= fun propmap ->
    let privileges = Properties.privileges ~auth_user_props propmap in
    Format.printf "privileges are %a\n%!" Fmt.(list ~sep:(unit "; ") Xml.pp_privilege) privileges ;
    Privileges.is_met ~requirement privileges

  (* moved from Caldav_server *)

let hash_password password =
  let server_secret = "server_secret--" in
  Cstruct.to_string @@ Nocrypto.Base64.encode @@
  Nocrypto.Hash.SHA256.digest @@ Cstruct.of_string (server_secret ^ password)

let verify_auth_header fs config v =
  match Astring.String.cut ~sep:"Basic " v with
  | Some ("", b64) ->
    begin match Nocrypto.Base64.decode (Cstruct.of_string b64) with
      | None -> Lwt.return @@ Error "invalid base64 encoding"
      | Some data -> match Astring.String.cut ~sep:":" (Cstruct.to_string data) with
        | None -> Lwt.return @@ Error "invalid user:password encoding"
        | Some (user, password) ->
          let hashed = hash_password password in
          Fs.get_property_map fs (`Dir [config.principals ; user]) >|= fun props ->
          (* no user context yet *)
          match Properties.unsafe_find (Xml.robur_ns, "password") props with
          | Some (_, [ Xml.Pcdata stored ]) ->
            if String.equal hashed stored
            then Ok user
            else Error "wrong password"
          | _ -> Error "invalid user"
    end
  | _ -> Lwt.return @@ Error "bad header"

let last_modified fs ~path =
  Fs.from_string fs path >>= function
  | Error _ -> Lwt.return None
  | Ok f_or_d ->
    Fs.get_property_map fs f_or_d >|= fun map ->
    (* no special property, already checked for resource *)
    match Properties.unsafe_find (Xml.dav_ns, "getlastmodified") map with
    | Some (_, [ Xml.Pcdata lm]) -> Some lm
    | _ -> None

let compute_etag fs ~path =
  Fs.from_string fs path >>= function
  | Error _ -> Lwt.return None
  | Ok f_or_d ->
    Fs.get_property_map fs f_or_d >|= fun map ->
    (* no special property, already checked for resource *)
    match Properties.unsafe_find (Xml.dav_ns, "getetag") map with
    | Some (_, [ Xml.Pcdata etag ]) -> Some etag
    | _ -> None

let server_ns = "http://calendarserver.org/ns/"
let carddav_ns = "urn:ietf:params:xml:ns:carddav"

let make_dir fs acl ?(resourcetype = []) ?(props=[]) dir =
  let propmap =
    Properties.create_dir ~initial_props:props ~resourcetype acl (Ptime_clock.now ()) (Fs.basename (dir :> Webdav_fs.file_or_dir))
  in
  Fs.mkdir fs dir propmap

let make_dir_if_not_present fs acl ?resourcetype ?props dir =
  Fs.dir_exists fs dir >>= fun exists ->
  if not exists then
    make_dir fs acl ?resourcetype ?props dir >|= fun _ -> ()
  else
    Lwt.return_unit

let grant_test config =
  let url = Uri.with_path config.host (Fs.to_string (`Dir [ config.principals ; "test" ])) in
  (Xml.dav_ns, "acl"), ([], [ Xml.ace_to_xml (`Href url, `Grant [ `Read ]) ; Xml.ace_to_xml (`Href url, `Grant [ `Write ]) ])

let deny_all = (Xml.dav_ns, "acl"), ([], [ Xml.ace_to_xml (`All, `Deny [ `All ]) ])
let grant_all = (Xml.dav_ns, "acl"), ([], [ Xml.ace_to_xml (`All, `Grant [ `All ]) ])

let create_calendar fs acl name =
  let props =
    let reports = [
      Xml.caldav_ns, "calendar-query" ;
      Xml.caldav_ns, "calendar-multiget" ;
   (* Xml.dav_ns, "acl-principal-prop-set" ;
      Xml.dav_ns, "principal-match" ;
      Xml.dav_ns, "principal-property-search" ;
      Xml.dav_ns, "expand-property" ;
      server_ns, "calendarserver-principal-search" ;
      Xml.caldav_ns, "free-busy-query" ;
      carddav_ns, "addressbook-query" ;
      carddav_ns, "addressbook-multiget" *)
   (* Xml.dav_ns, "sync-collection" *)
    ] in
    let report_nodes =
      List.map (fun (ns, s) ->
          Xml.dav_node "supported-report"
            [ Xml.dav_node "report" [ Xml.node ~ns s [] ] ])
        reports
    in
    let comps =
      List.map (fun s ->
          Xml.node ~ns:Xml.caldav_ns "comp" ~a:[(("", "name"), s)] [])
        [ "VEVENT" ; "VTODO" ; "VTIMEZONE" ; "VFREEBUSY" ]
    in
    [
      (Xml.dav_ns, "supported-report-set"), ([], report_nodes) ;
      (Xml.caldav_ns, "supported-calendar-component-set"), ([], comps) ;
      (* (server_ns, "getctag"), ([], [ Xml.pcdata "hallo" ]) *)
      (* (Xml.dav_ns, "owner"), ([], [ Xml.pcdata "/principals/__uids__/10000000-0000-0000-0000-000000000001" ]) ; *)
    ] in
  let resourcetype = [ Xml.node ~ns:Xml.caldav_ns "calendar" [] ] in
  make_dir_if_not_present fs acl ~resourcetype ~props name

let initialize_fs_for_apple_testsuite fs config =
  let calendars_properties =
    let url =
      Uri.with_path config.host
        (config.calendars ^ "/__uids__/10000000-0000-0000-0000-000000000001/calendar")
    in
    [
    (Xml.caldav_ns, "calendar-home-set"),
    ([], [Xml.node "href" ~ns:Xml.dav_ns [Xml.pcdata (Uri.to_string url) ]])
  ] in
  let acl = config.default_acl in
  make_dir_if_not_present fs acl ~props:calendars_properties (`Dir [config.calendars]) >>= fun _ ->
  make_dir_if_not_present fs acl (`Dir [config.calendars ; "users"]) >>= fun _ ->
  make_dir_if_not_present fs acl (`Dir [config.calendars ; "__uids__"]) >>= fun _ ->
  make_dir_if_not_present fs acl (`Dir [config.calendars ; "__uids__" ; "10000000-0000-0000-0000-000000000001"]) >>= fun _ ->
  create_calendar fs acl (`Dir [config.calendars ; "__uids__" ; "10000000-0000-0000-0000-000000000001" ; "calendar" ]) >>= fun _ ->
  make_dir_if_not_present fs acl (`Dir [config.calendars ; "__uids__" ; "10000000-0000-0000-0000-000000000001" ; "tasks"]) >>= fun _ ->
  Lwt.return_unit

let initialize_fs fs config =
  make_dir_if_not_present fs config.default_acl (`Dir [config.principals]) >>= fun _ ->
  make_dir_if_not_present fs config.default_acl (`Dir [config.calendars]) >>= fun _ ->
  Lwt.return_unit

(* use config.user_password for initial structure
  /principals/ -- config.principals WebDAV
  /principals/user/ -- WebDAV -- principal-URL for user user, prop.xml <- contains calendar-home-set
  /calendars/  -- config.calendars WebDAV
  /calendars/user/ -- WebDAV
  /calendars/user/calendar/ -- CalDAV - default calendar
  /calendars/user/my_other_calendar/ -- CalDAV

PROPFIND /calendars -- eingeloggt als user -- <principal-URL>
--> <principal-URL>http://.../principals/user/

PROPFIND /principals/user -- <calendar-home-set>
--> <calendar-home-set><href>http://.../calendars/user/</calendar-home-set>
 *)

let make_user ?(props = []) fs config name password =
  let resourcetype = [ Xml.node ~ns:Xml.dav_ns "principal" [] ] in
  let get_url dir = Uri.with_path config.host (Fs.to_string (dir :> Webdav_fs.file_or_dir)) in
  let principal_dir = `Dir [ config.principals ; name ] in
  let principal_url = get_url principal_dir in
  let home_set_dir = `Dir [ config.calendars ; name ] in
  let home_set_url = get_url home_set_dir in
  let props' =
    ((Xml.dav_ns, "principal-URL"),
     ([], [ Xml.node ~ns:Xml.dav_ns "href" [ Xml.pcdata @@ Uri.to_string principal_url ] ]))
    :: ((Xml.caldav_ns, "calendar-home-set"),
        ([], [Xml.dav_node "href" [Xml.pcdata @@ Uri.to_string home_set_url ]]))
    :: ((Xml.robur_ns, "password"),
        ([], [Xml.pcdata @@ hash_password password]))
    :: props
  in
  let acl = [ (`Href principal_url, `Grant [ `All ]) ; (`All, `Grant [ `Read ]) ] in
  (* TODO should root have access to principals/user? *)
  make_dir_if_not_present fs acl ~resourcetype ~props:props' principal_dir >>= fun _ ->
  make_dir_if_not_present fs acl home_set_dir >>= fun _ ->
  create_calendar fs acl (`Dir [config.calendars ; name ; "calendar"]) >>= fun _ ->
  Lwt.return_unit

let make_group fs config name password members =
  let principal_path user = Fs.to_string (`Dir [ config.principals ; user ]) in
  let new_member_paths = List.map principal_path members in
  let new_member_urls =
    List.map
      (fun path -> Uri.to_string @@ Uri.with_path config.host path)
      new_member_paths
  in
  let group_props = [
    (Xml.dav_ns, "group-member-set"),
    ([], List.map (fun u -> Xml.dav_node "href" [ Xml.pcdata u ]) new_member_urls)
  ] in
  make_user ~props:group_props fs config name password >>= fun () ->
  let group_node =
    Xml.dav_node "href"
      [ Xml.pcdata (Uri.to_string @@ Uri.with_path config.host (principal_path name)) ]
  in
  let group_key = (Xml.dav_ns, "group-membership") in
  Lwt_list.iter_p (fun path ->
      let f_or_d = (Fs.dir_from_string path :> Webdav_fs.file_or_dir) in
      Fs.get_property_map fs f_or_d >>= fun props ->
      (* TODO should use find_many *)
      let props' = match Properties.unsafe_find group_key props with
        | None -> Properties.unsafe_add group_key ([], [ group_node ]) props
        | Some (attrs, groups) -> Properties.unsafe_add group_key (attrs, group_node :: groups) props
      in
      Fs.write_property_map fs f_or_d props' >>= fun _ ->
      Lwt.return_unit)
    new_member_paths

end
