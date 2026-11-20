#Author: Benjamin Pyatski
#Company: Chory Lab
#Purpose: Test basic movements of Hamilton Star through PyHamilton with integration of transfer_station system

import os
import sys
import serial
import requests

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

#flask IP address
url = 'http://10.146.92.218:5000'

# Longest a transfer station move can take: 52000 half-steps at 2.5 ms each,
# plus margin. A move that fails takes this long before reporting it.
TRANSFER_TIMEOUT = 240  # seconds


class TransferStationError(RuntimeError):
    """ The transfer station did not confirm the plate is in position """


def move_transfer_station(command):
    """ Send 'go_left' or 'go_right' and wait for the move to finish.

    The robot acts on the plate at a fixed position, so carrying on after a
    move that fell short would miss it. Raises TransferStationError unless the
    limit switch at that end confirmed the cart arrived. """
    expected = {'go_left': 'reached_left', 'go_right': 'reached_right'}[command]
    try:
        response = requests.post(url, data=command, timeout=TRANSFER_TIMEOUT)
    except requests.RequestException as error:
        raise TransferStationError(
            '{}: no response from the transfer station: {}'.format(command, error)) from error
    try:
        body = response.json()
    except ValueError:
        body = {'result': response.text[:200]}
    if response.status_code != 200 or body.get('result') != expected:
        raise TransferStationError('{} failed (HTTP {}): {}'.format(
            command, response.status_code, body))
    print('transfer station {} after {} steps'.format(body['result'], body.get('steps')))
    return body

if __name__ == '__main__':

    with HamiltonInterface(simulate=True) as ham_int:
        normal_logging(ham_int, os.getcwd())
        initialize(ham_int)

        #send request to transfer_station raspberry pi through flask IP address
        move_transfer_station('go_right')

        
        move_plate(ham_int, plate_1, plate_2, gripHeight=10.0, gripWidth=80.0, gripMode=0, widthBefore = 100.0)
        #  grip_height=6.0, gripWidth=80.0, gripMode=0, widthBefore = 100.0


        move_transfer_station('go_left')

        a.write(bytes('mv:ts 010\r', encoding='utf-8'))
        # requests.post(url, data='go_right')
        # move_plate(ham_int, plate_2, plate_1, gripHeight=10.0, gripWidth=80.0, gripMode=0, widthBefore = 100.0)
        
        # tip_pick_up(ham_int, tips)
        # aspirate(ham_int, wells_1, vols, liquidClass="HighVolume_Water_DispenseJet_Empty")
        # dispense(ham_int, wells_3, vols, liquidClass="HighVolume_Water_DispenseJet_Empty")
        # tip_eject(ham_int, tips)
        # move_by_seq(ham_int, 'Nun_96_FL_HB_0004_lid', 'Nun_96_FL_HB_0001_lid', grip_height=6.0, gripWidth=80.0, gripMode=0, widthBefore = 100.0)
