import os
import sys
import serial

from pyhamilton import *

liq_class = 'StandardVolumeFilter_Water_DispenseJet_Empty'

lmgr = LayoutManager('Test_1.lay')

plate_1 = layout_item(lmgr, Plate96, 'Nun_96_Fl_HB_0001')
plate_2 = layout_item(lmgr, Plate96, 'Nun_96_Fl_HB_0002')
plate_3 = layout_item(lmgr, Plate96, 'Nun_96_Fl_HB_0003')

tip_carrier = (layout_item(lmgr, Tip96, 'HT_L_0001'))

tips = [(tip_carrier, x) for x in range(8)]
wells_1 = [(plate_1, x) for x in range(8)]
wells_3 = [(plate_3, x) for x in range(8)]
vols = [30 for x in range(8)]
a = serial.Serial("COM5", 9600, timeout=1)

url = 'http://10.146.92.218:5000'

if __name__ == '__main__':

    with HamiltonInterface(simulate=True) as ham_int:
        normal_logging(ham_int, os.getcwd())
        initialize(ham_int)
        requests.post(url, data='go_right')

        
        move_plate(ham_int, plate_1, plate_2, gripHeight=10.0, gripWidth=80.0, gripMode=0, widthBefore = 100.0)
        #  grip_height=6.0, gripWidth=80.0, gripMode=0, widthBefore = 100.0


        requests.post(url, data='go_left')

        a.write(bytes('mv:ts 010\r', encoding='utf-8'))
        # requests.post(url, data='go_right')
        # move_plate(ham_int, plate_2, plate_1, gripHeight=10.0, gripWidth=80.0, gripMode=0, widthBefore = 100.0)
        
        # tip_pick_up(ham_int, tips)
        # aspirate(ham_int, wells_1, vols, liquidClass="HighVolume_Water_DispenseJet_Empty")
        # dispense(ham_int, wells_3, vols, liquidClass="HighVolume_Water_DispenseJet_Empty")
        # tip_eject(ham_int, tips)
        # move_by_seq(ham_int, 'Nun_96_FL_HB_0004_lid', 'Nun_96_FL_HB_0001_lid', grip_height=6.0, gripWidth=80.0, gripMode=0, widthBefore = 100.0)
