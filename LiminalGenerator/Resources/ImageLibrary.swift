//
//  ImageLibrary.swift
//  LiminalGenerator
//
//  Manifest of the bundled liminal-space image library.
//
//  Source-folder -> asset-name mapping (alphabetical order of source folder
//  name under img/stitch_liminal_space_generator/, excluding generator_player,
//  share_clip, liminal_analog, and the "VHS timestamp reference images" folder):
//
//   01  a_portrait_oriented_liminal_space_image_of_a_deserted_bowling_alley_at_night        -> liminal_01
//   02  a_portrait_oriented_liminal_space_image_of_a_deserted_bus_station_with_empty         -> liminal_02
//   03  a_portrait_oriented_liminal_space_image_of_a_deserted_children_s_play_area_in_a      -> liminal_03
//   04  a_portrait_oriented_liminal_space_image_of_a_deserted_indoor_swimming_pool_1         -> liminal_04
//   05  a_portrait_oriented_liminal_space_image_of_a_deserted_indoor_swimming_pool_2         -> liminal_05
//   06  a_portrait_oriented_liminal_space_image_of_a_deserted_subway_platform_with           -> liminal_06
//   07  a_portrait_oriented_liminal_space_image_of_a_deserted_underground_parking            -> liminal_07
//   08  a_portrait_oriented_liminal_space_image_of_a_dimly_lit_empty_hotel_corridor          -> liminal_08
//   09  a_portrait_oriented_liminal_space_image_of_a_foggy_empty_parking_lot_at_night        -> liminal_09
//   10  a_portrait_oriented_liminal_space_image_of_a_vacant_arcade_with_rows_of_dark         -> liminal_10
//   11  a_portrait_oriented_liminal_space_image_of_a_vacant_banquet_hall_with_stacked        -> liminal_11
//   12  a_portrait_oriented_liminal_space_image_of_a_vacant_hospital_waiting_room_with       -> liminal_12
//   13  a_portrait_oriented_liminal_space_image_of_a_vacant_laundromat_with_rows_of          -> liminal_13
//   14  a_portrait_oriented_liminal_space_image_of_an_empty_brightly_lit_grocery_store       -> liminal_14
//   15  a_portrait_oriented_liminal_space_image_of_an_empty_dimly_lit_shopping_mall_at_2     -> liminal_15
//   16  a_portrait_oriented_liminal_space_image_of_an_empty_library_with_towering            -> liminal_16
//   17  a_portrait_oriented_liminal_space_image_of_an_empty_movie_theater_with_red           -> liminal_17
//   18  a_portrait_oriented_liminal_space_image_of_an_empty_office_floor_with_rows_of_1      -> liminal_18
//   19  a_portrait_oriented_liminal_space_image_of_an_empty_office_floor_with_rows_of_2      -> liminal_19
//   20  a_portrait_oriented_liminal_space_image_of_an_empty_school_hallway_at_night          -> liminal_20
//   21  a_portrait_oriented_liminal_space_image_of_an_empty_storage_facility_with_long       -> liminal_21
//   22  a_portrait_oriented_liminal_space_image_of_an_endless_airport_terminal_with_1        -> liminal_22
//   23  a_portrait_oriented_liminal_space_image_of_an_endless_airport_terminal_with_2        -> liminal_23
//
//  NOTE: SPEC.md and the scaffolding task both describe 24 library images
//  ("liminal_01" ... "liminal_24"). At scaffold time the
//  img/stitch_liminal_space_generator/ directory contained only 23 folders
//  matching the "a_portrait_oriented*" prefix (verified by directory
//  listing). This manifest therefore ships 23 images (liminal_01...
//  liminal_23). If a 24th source image is added later, append it here and
//  to the asset catalog as liminal_24.
//

import Foundation

/// A single entry in the bundled liminal-space image library.
struct LiminalImage: Identifiable, Hashable {
    /// 1-based position in the library (also encoded in `assetName`).
    let id: Int
    /// Name of the imageset in Assets.xcassets.
    let assetName: String
    /// Short, human-readable, uppercase location name for the OSD / UI.
    let locationName: String
}

/// Static manifest of every image bundled in Assets.xcassets.
enum ImageLibrary {
    static let images: [LiminalImage] = [
        LiminalImage(id: 1,  assetName: "liminal_01", locationName: "BOWLING ALLEY"),
        LiminalImage(id: 2,  assetName: "liminal_02", locationName: "BUS STATION"),
        LiminalImage(id: 3,  assetName: "liminal_03", locationName: "PLAY AREA"),
        LiminalImage(id: 4,  assetName: "liminal_04", locationName: "SWIMMING POOL 1"),
        LiminalImage(id: 5,  assetName: "liminal_05", locationName: "SWIMMING POOL 2"),
        LiminalImage(id: 6,  assetName: "liminal_06", locationName: "SUBWAY PLATFORM"),
        LiminalImage(id: 7,  assetName: "liminal_07", locationName: "UNDERGROUND PARKING"),
        LiminalImage(id: 8,  assetName: "liminal_08", locationName: "HOTEL CORRIDOR"),
        LiminalImage(id: 9,  assetName: "liminal_09", locationName: "PARKING LOT"),
        LiminalImage(id: 10, assetName: "liminal_10", locationName: "ARCADE"),
        LiminalImage(id: 11, assetName: "liminal_11", locationName: "BANQUET HALL"),
        LiminalImage(id: 12, assetName: "liminal_12", locationName: "HOSPITAL WAITING ROOM"),
        LiminalImage(id: 13, assetName: "liminal_13", locationName: "LAUNDROMAT"),
        LiminalImage(id: 14, assetName: "liminal_14", locationName: "GROCERY STORE"),
        LiminalImage(id: 15, assetName: "liminal_15", locationName: "SHOPPING MALL"),
        LiminalImage(id: 16, assetName: "liminal_16", locationName: "LIBRARY"),
        LiminalImage(id: 17, assetName: "liminal_17", locationName: "MOVIE THEATER"),
        LiminalImage(id: 18, assetName: "liminal_18", locationName: "OFFICE FLOOR 1"),
        LiminalImage(id: 19, assetName: "liminal_19", locationName: "OFFICE FLOOR 2"),
        LiminalImage(id: 20, assetName: "liminal_20", locationName: "SCHOOL HALLWAY"),
        LiminalImage(id: 21, assetName: "liminal_21", locationName: "STORAGE FACILITY"),
        LiminalImage(id: 22, assetName: "liminal_22", locationName: "AIRPORT TERMINAL 1"),
        LiminalImage(id: 23, assetName: "liminal_23", locationName: "AIRPORT TERMINAL 2"),
    ]

    static var count: Int { images.count }

    static subscript(index: Int) -> LiminalImage {
        images[((index % count) + count) % count]
    }
}
