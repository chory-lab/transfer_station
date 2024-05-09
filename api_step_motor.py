#Author: Benjamin Pyatski
#Company: Chory Lab

#to add flask respository 
#export FLASK_APP=name.py

#to run code
#flask --app api_step_motor run

import os
from flask import Flask, render_template, request, jsonify
import RPi.GPIO as GPIO
import time
from flask_caching import Cache
import redis
import A4988    

print(__name__)
app = Flask(__name__, template_folder = '/home/chorylab/transfer_station/templates')
app.config['CACHE_TYPE'] = 'RedisCache' 
cache = Cache(app)

bool_to_string = {True:'True', False: 'False'}
string_to_bool = {'True':True, 'False': False, None: None}

################################
# RPi and Motor Pre-allocations
################################

#GPIO.setmode(GPIO.BOARD)

#define GPIO pins
direction= 22 # Direction (DIR) GPIO Pin
step = 23 # Step GPIO Pin
EN_pin = 24# enable pin (LOW to enable)

# Declare a instance of class pass GPIO pins numbers and the motor type
my_motor = A4988.A4988Nema(direction, step, (11,9,10), "A4988", cache)    

GPIO.setup(EN_pin,GPIO.OUT) # set enable pin as output

cache.set('motor_stop', 'False')

opened_page = cache.get('has_opened_page')
if opened_page == None:
    cache.set('has_opened_page', 'True')
    cache.set('motor_moving', 'False')

@app.route('/', methods=['GET', 'POST'])
def index():
    if request.method == 'POST':
        if request.form.get('stop_motor') == 'Stop Motor':
            cache.set('motor_stop', 'True')
            return render_template('buttons.html')
            
        #dropbox
        try:
            direction = string_to_bool[request.form['direction']]
        except:
            direction = True
    
        #hit boxes
        try:
            step_num = int(request.form['step_num'])         
        except:
            step_num = 26000
        try:
            step_delay = float(request.form['step_delay'])
        except:
            step_delay = 0.00000000000005
        
        #go left till end button
        if request.form.get('go_left') == 'Go Left' or request.get_data() == b'go_left':
            string = move_test(False, step_num, step_delay)
            return render_template('buttons.html')
        
        #go right till end button
        if request.form.get('go_right') == "Go Right" or request.get_data() == b'go_right': 
            string = move_test(True, step_num, step_delay)
            return render_template('buttons.html')
        
        #button
        if request.form.get('run_motor') == 'Run Motor':
            string = move_test(direction, step_num, step_delay)
            return render_template('buttons.html')
        
    elif request.method == 'GET':        
        return render_template('buttons.html')            

@app.route('/status')
def status():
    state = cache.get('motor_moving')
    return state

@app.route('/move_test')
def move_test(direction, step_num, step_delay):
    motor_moving = string_to_bool[cache.get('motor_moving')]
        
    if motor_moving:
        return "move_test already running"    
    else:
        cache.set('motor_moving', 'True')
        ###########################
        # Actual motor control
        ###########################
        #
        GPIO.output(EN_pin,GPIO.LOW) # pull enable to low to enable motor
        
        print("running motor")
        my_motor.motor_go(direction, # True=Clockwise, False=Counter-Clockwise
                        "Half" , # Step type (Full,Half,1/4,1/8,1/16,1/32)
                        step_num, # number of steps
                        step_delay, # step delay [sec]
                        True, # True = print verbose output 
                        .05) # initial delay [sec]
        GPIO.output(EN_pin,GPIO.HIGH)
        
        cache.set('motor_moving', 'False')
        
        return "Motor Running"
    
if __name__ == '__main__':
    app.run(host="0.0.0.0", port=5000, debug=True)

