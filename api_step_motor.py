#Author: Benjamin Pyatski
#Company: Chory Lab

import os
from flask import Flask, render_template, request, jsonify
import RPi.GPIO as GPIO
import time
from flask_caching import Cache
import redis
import A4988    

print(__name__)
app = Flask(__name__, template_folder=os.path.join(os.path.dirname(__file__), 'templates'))
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

# Go Left / Go Right drive until the limit switch at that end is pressed. This
# is only the most steps a move may take before giving up. The full stroke is
# nominally 26000 half-steps, but the motor has lost steps on the way, so allow
# twice that: a healthy move stops at its switch long before reaching it.
MAX_TRAVEL_STEPS = 52000

# HTTP status for each way a move can fail
FAILURE_STATUS = {
    'busy': 409,
    A4988.STOPPED: 409,
    A4988.COMPLETED: 500,  # used every step without reaching the switch
    A4988.SWITCH_FAULT: 500,
    A4988.ERROR: 500,
}

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
            step_num = MAX_TRAVEL_STEPS
        try:
            step_delay = float(request.form['step_delay'])
        except:
            # Applied to both the high and low phase of each pulse, so the
            # step period is 2*step_delay -> 400 half-steps/s = 200 full
            # steps/s = 1 rev/s. Sits inside the A4988 pull-in region, so
            # the motor starts from rest without ramping and won't stall.
            step_delay = 0.00125
        
        #go left till end button
        if request.get_data() == b'go_left':
            return as_json(*travel_to_end(False, step_num, step_delay))
        if request.form.get('go_left') == 'Go Left':
            return show(*travel_to_end(False, step_num, step_delay))
        
        #go right till end button
        if request.get_data() == b'go_right':
            return as_json(*travel_to_end(True, step_num, step_delay))
        if request.form.get('go_right') == "Go Right": 
            return show(*travel_to_end(True, step_num, step_delay))
        
        #button: a set number of steps, still stopping at a limit switch
        if request.form.get('run_motor') == 'Run Motor':
            outcome = move_test(direction, step_num, step_delay)
            if outcome['result'] in (A4988.COMPLETED, A4988.LIMIT):
                return show(outcome, 200)
            return show(outcome, FAILURE_STATUS[outcome['result']])
        
    elif request.method == 'GET':        
        return render_template('buttons.html')            

def travel_to_end(clockwise, step_num, step_delay):
    """ Drive to the end of the rail. Succeeds only when that end's limit
    switch confirms the cart arrived. Returns (body, http_status). """
    end = 'right' if clockwise else 'left'
    outcome = move_test(clockwise, step_num, step_delay)
    if outcome['result'] == A4988.LIMIT:
        outcome['result'] = 'reached_' + end
        return outcome, 200
    if outcome['result'] == A4988.COMPLETED:
        outcome['result'] = 'short_of_' + end
    return outcome, FAILURE_STATUS.get(outcome['result'], 500)

def as_json(outcome, http_status):
    return jsonify(outcome), http_status

def show(outcome, http_status):
    message = 'Move {}: {} steps'.format(outcome['result'], outcome['steps'])
    return render_template('buttons.html', message=message), http_status

@app.route('/status')
def status():
    state = cache.get('motor_moving')
    return state

@app.route('/position')
def position():
    return jsonify(moving=string_to_bool[cache.get('motor_moving')] is True,
                   at_left=A4988.at_limit(A4988.LIMIT_LEFT_PIN),
                   at_right=A4988.at_limit(A4988.LIMIT_RIGHT_PIN))

@app.route('/move_test')
def move_test(direction, step_num, step_delay):
    motor_moving = string_to_bool[cache.get('motor_moving')]
        
    if motor_moving:
        return {'result': 'busy', 'steps': 0}
    else:
        cache.set('motor_moving', 'True')
        # A Stop pressed while idle would otherwise cancel this move at once
        cache.set('motor_stop', 'False')
        ###########################
        # Actual motor control
        ###########################
        #
        GPIO.output(EN_pin,GPIO.LOW) # pull enable to low to enable motor
        
        print("running motor")
        result, steps = my_motor.motor_go(direction, # True=Clockwise, False=Counter-Clockwise
                        "Half" , # Step type (Full,Half,1/4,1/8,1/16,1/32)
                        step_num, # number of steps
                        step_delay, # step delay [sec]
                        True, # True = print verbose output 
                        .05) # initial delay [sec]
        GPIO.output(EN_pin,GPIO.HIGH)
        
        cache.set('motor_moving', 'False')
        print("move ended: {} after {} steps".format(result, steps))
        
        return {'result': result, 'steps': steps}
    
if __name__ == '__main__':
    app.run(host="0.0.0.0", port=5000, debug=True)

