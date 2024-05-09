<h1>Introduction</h1>
This repository holds the code (and previously used test code) for the functioning of the transfer system, or just the step motor rail. There are two parts to this README detailing the software components, and the hardware components of the transfer station system.

<h2>Software</h2>
This section details the usage of the code.

<h3>api_step_motor.py</h3>
The system is setup in such a way where the majority of the fucntional code is in api_step_motor, which creates a UI through flask (and handles subsequent interactions with said UI) that the user can input commands to. 

<h3>A4988.py</h3>
In order for the stepper motor to connect to the Raspberry Pi 4 it is necessary to utilize a A4988 controller, and the python file of the same name holds all the function definitions utilized in api_step_motor.py and the microswitches, and handles the connection between the Raspberry Pi 4 and the stepper motor on the rail.

<h3>Installation</h3>

* Install flask (make sure it is ver 2.2.2 or newer otherwise --app feature won't work, check this by running flask --version):
  
    ```pip install --upgrade Flask ```

* Install reddis:

    ```pip install redis```

* Install flask_caching:
  
    ```pip install flask_caching```

<h3>Setup (Skip if setup already running)</h3>
The first step is to get start the flask and redis server, the redis server handling multiple calls at the same time to allow asynchronous running of the code. 
<br><br>

1. Activate the Virtual Environment
    - Navigate to the location of the virtual environment:
    
      ```cd /home/git/transfer_station```
    - Activate the virtual environment:
    
      ```source foobar/bin/activate```
    
2. In another terminal, start the redis server:
   
    ```redis-server```  

4. Run the code through flask (on the previously setup virtual environment) and open the outputted link (first one is for the local machine, second is for a different machine on the same wifi):

    ```flask --app api_step_motor run --host=0.0.0.0```

<h2>Hardware</h2>
The hardware can be categorized into two parts, the actual circuitry required to run the transfer station, and then the physical components that actually make up the parts of the transfer station itself. 

<h3>Transfer Station Circuitry</h3>
The transfer station consists of a step motor rail connected through a motor driver (A4988 Stepper Motor Driver) to a computer (Raspberry Pi Zero 2 W) on which the code is running. The wiring diagram can be seen below:

![image](https://github.com/chory-lab/transfer_station/assets/69654071/a2e29e91-b305-4fbc-8b5c-8c84075bc933)

<h3>Transfer Station System</h3>
The system is composed of 4 core components, these consist of the tray, tray platform, step motor rail system, and the mount.

<h4>Tray</h4>
This is holds the 96 well plate (or equivalent size) when delivering the plate to the incubator, and vice versa.

![image](https://github.com/chory-lab/transfer_station/assets/69654071/5e6d066a-dbb4-403d-9bdd-c4cc44f140a3)

<h4>Tray Platform</h4>
This raises the tray to the needed height for the incubator to be able to reach the plate.

![image](https://github.com/chory-lab/transfer_station/assets/69654071/3565bda2-becf-4eeb-828e-3ba721c507a8)

<h4>Stepper Motor Rail System</h4>
This comprises of a stepper motor, connected to a rail system (screw) that spins moving a cart that is already on the screw.

![image](https://github.com/chory-lab/transfer_station/assets/69654071/2178c803-b7bc-447f-a207-de881839ab26)

<h4>Mount</h4>
This is what the stepper motor rail system is screwed onto connecting/supporting the stepper motor rail system on the incubator.

![image](https://github.com/chory-lab/transfer_station/assets/69654071/741e2487-255b-4564-998c-046b475df2dc)

<h4>Assembly</h4>
The final assembly consists of screwing the mount onto the incubator, then screwing the stepper motor rail system to the mount, screwing the tray platform onto the stepper motor rail system, and then finally attaching the tray onto the tray platform by sliding the two circular mounts on the tray platform into the holes on the tray.

![image](https://github.com/chory-lab/transfer_station/assets/69654071/efbe3aa6-5773-4725-8d5d-f140b0767e20)
