# frozen_string_literal: true

module MyExtensions
  module ElectricalCalculator
    module InputDevicesData

      # Path to .skp component files
      COMPONENTS_DIR = File.join(EXTENSION_ROOT,'components').freeze

      # Device definitions: [label, skp_file, connection_type]
      # connection_type: plug, switch, ceiling, floor, wall, switchboard
      DEVICES_TAB = [
        ["3 Gang Switches",                       "3 gang switches.skp",                     "wall"],
        ["4.5 Inches LED",                        "4.5InchesLED.skp",                        "ceiling"],
        ["4.5 Inches LED Square",                 "4.5InchesLEDsquare.skp",                  "ceiling"],
        ["AC 12000BTU1500VA",                     "AC12000BTU1500VA.skp",                     "wall"],
        ["AC 18000BTU1700VA",                     "AC18000BTU1700VA.skp",                     "wall"],
        ["CAT 6 Dual Point",                      "CAT6dualpoint.skp",                       "wall"],
        ["CAT 6 Point",                           "CAT6point.skp",                           "wall"],
        ["CAT 6 Quad Point",                      "CAT6quadpoint.skp",                       "wall"],
        ["Ceiling Light",                         "Light.skp",                               "ceiling"],
        ["Chome DownLight",                       "Chome_DownLight.skp",                     "ceiling"],
        ["Chomegridlamp_2tube",                   "Chomegridlamp_2tube.skp",                 "ceiling"],
        ["Chomegridlamp_4tube",                   "Chomegridlamp_4tube.skp",                 "ceiling"],
        ["ChomeLED Panel 0.3x1.2m Recess",        "ChomeLEDPanel0.3x1.2mRecess.skp",       "ceiling"],
        ["ChomeLEDPanel60x60Recess",               "ChomeLEDPanel60x60Recess.skp",            "ceiling"],
        ["Chome_hang_cylinder",                   "Chome_hang_cylinder.skp",                 "ceiling"],
        ["ChomePendantLamp",                      "ChomePendantLamp.skp",                    "ceiling"],
        ["Chandelier Light",                      "Chandelier_Light.skp",                    "ceiling"],
        ["ChandelierHex",                         "ChandelierHex.skp",                       "ceiling"],
        ["Circle Fluorescent_32W",                "Circle Fluorescent_32W.skp",              "ceiling"],
        ["Consumer Unit_SQD",                     "Consumer Unit_SQD.skp",                    "wall"],
        ["Cube Light (Wall)",                     "WallLightSquare.skp",                     "wall"],
        ["Door Bell",                             "DoorBell.skp",                            "wall"],
        ["Door Entry",                            "DoorEntry.skp",                           "wall"],
        ["Duplex Receptacle",                     "Duplex receptacle.skp",                   "wall"],
        ["Duplex Receptacle GFI",                 "Duplex receptacle GFI.skp",               "wall"],
        ["Duplex Receptacle WP GFI",              "Duplex receptacle WP GFI.skp",            "wall"],
        ["Double Downlight Box",                  "DoubleDownlight_box.skp",                 "ceiling"],
        ["Downlight Floating",                    "DownlightFloating.skp",                   "ceiling"],
        ["Downlight Square Float",                "DownlightSquare_Float.skp",                "ceiling"],
        ["Downlight Sqrt Wall",                   "DownlightSqrt_Wall.skp",                  "wall"],
        ["Downlight Wall",                        "DownlightWall.skp",                       "wall"],
        ["Fan with Light",                        "LightFan.skp",                            "ceiling"],
        ["Fluorescent 1X18W",                     "Fluorescent_1X18W.skp",                   "ceiling"],
        ["Fluorescent 1X36W",                     "Fluorescent_1x36W.skp",                   "ceiling"],
        ["Fluorescent 2X36W",                     "Fluorescent_2X36W.skp",                   "ceiling"],
        ["Hoven Plug",                            "HovenPlug.skp",                           "wall"],
        ["Key Pad",                               "keypad.skp",                              "wall"],
        ["LED Ceiling Light",                     "LEDlight.skp",                            "ceiling"],
        ["LED Light Module (Wall)",               "LedLightModule.skp",                      "wall"],
        ["Neon Tube",                             "NeonTube.skp",                            "ceiling"],
        ["NeonSigle 0.6m",                        "NeonSigle_0.6m.skp",                       "ceiling"],
        ["Neon Twin 1.2m",                        "NeonTwin_1.2m.skp",                       "ceiling"],
        ["NeonSingle 12m",                        "NeonSingle_12m.skp",                      "ceiling"],
        ["Neon_long_outside",                     "Neon_long_outside.skp",                   "ceiling"],
        ["NeonLongTwin_float",                    "NeonLongTwin_float.skp",                  "ceiling"],
        ["Plug",                                  "Plug.skp",                                "wall"],
        ["Plug x 2",                              "Plug_double.skp",                         "wall"],
        ["Panel Box 350x520x170",                 "Panel350x520x170.skp",                     "wall"],
        ["Recep Duplex",                          "Recep Duplex.skp",                        "wall"],
        ["Receptacle Dluplex",                    "Receptacle Dluplex.skp",                   "wall"],
        ["Receptacle USB",                        "Receptacle USB.skp",                      "wall"],
        ["Recessed LED Housing",                  "RecessedLEDlight.skp",                    "cemiling"],
        ["RJ45 Plug",                             "RJ45plug.skp",                            "wall"],
        ["SportLight (Wall)",                     "SportLight_wall.skp",                     "wall"],
        ["SW 1 Gang",                             "SW 1 Gang.skp",                           "wall"],
        ["SW 2 Gang",                             "SW 2 Gang.skp",                           "wall"],
        ["SW 3 Gang",                             "SW 3 Gang.skp",                           "wall"],
        ["SW2 Gang (OneWay1_TwoWay1)",            "SW2 Gang (OneWay1_TwoWay1).skp",           "wall"],
        ["SW3 Gang (OneWay1_TwoWay2)",            "SW3 Gang (OneWay1_TwoWay2).skp",           "wall"],
        ["SW3 Gang (OneWay2_TwoWay1)",           "SW3 Gang (OneWay2_TwoWay1).skp",            "wall"],
        ["Switch Board",                          "SwitchBoard.skp",                         "wall"],
        ["Switch Double",                         "double_switch.skp",                       "wall"],
        ["Switch Single",                         "simple_switch.skp",                       "wall"],
        ["Telephone Plug",                        "telephonePlug.skp",                       "wall"],
        ["TrackLight",                            "TrackLight.skp",                          "ceiling"],
        ["TV Plug",                               "coaxialTV.skp",                           "wall"],
        ["Wall Light",                            "WallLight.skp",                           "wall"],
        ["WallLightClassic",                      "WallLightClassic.skp",                    "wall"],
        ["WallLightCylinder",                     "WallLightCylinder.skp",                   "wall"],
        ["WallLightSquare",                       "WallLightSquare.skp",                     "wall"],
        ["Waterproof Switch",                     "waterproof_switch.skp",                   "wall"],
].freeze

      # Wire type definitions: [label, nb_wires, wire_section_or_type]
      WIRE_TYPES_TAB = [
        # Metric (mm2)
        ["2 x 1.5 mm²",    "2", "1.5"],
        ["3 x 1.5 mm²",    "3", "1.5"],
        ["4 x 1.5 mm²",    "4", "1.5"],
        ["5 x 1.5 mm²",    "5", "1.5"],
        ["7 x 1.5 mm²",    "7", "1.5"],
        ["2 x 2.5 mm²",    "2", "2.5"],
        ["3 x 2.5 mm²",    "3", "2.5"],
        ["5 x 2.5 mm²",    "5", "2.5"],
        ["7 x 2.5 mm²",    "7", "2.5"],
        ["2 x 6.0 mm²",    "2", "6.0"],
        ["3 x 6.0 mm²",    "3", "6.0"],
        ["5 x 6.0 mm²",    "5", "6.0"],
        ["2 x 10.0 mm²",   "2", "10.0"],
        ["3 x 10.0 mm²",   "3", "10.0"],
        ["5 x 10.0 mm²",   "5", "10.0"],
        ["2 x 16.0 mm²",   "2", "16.0"],
        ["3 x 16.0 mm²",   "3", "16.0"],
        ["5 x 16.0 mm²",   "5", "16.0"],
        ["5 x 35.0 mm²",   "5", "35.0"],
        # Data / Telecom
        ["1 x RJ 45",      "1", "RJ45"],
        ["1 x TV",          "1", "TV"],
        ["1 x Telephone",   "1", "Telephone"],
      ].freeze

      # Connection type labels for UI filter buttons
      CONNECTION_TYPES = {
        'all'         => 'All',
        'wall'        => 'Wall',
        'ceiling'     => 'Ceiling/Floor',
        }.freeze

    end
  end
end
