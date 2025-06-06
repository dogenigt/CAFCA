<pre>
          O))         O)       O))))))))    O))         O)       
       O))   O))     O) ))     O))       O))   O))     O) ))     
      O))           O)  O))    O))      O))           O)  O))    
      O))          O))   O))   O))))))  O))          O))   O))   
      O))         O)))))) O))  O))      O))         O)))))) O))  
       O))   O)) O))       O)) O))       O))   O)) O))       O)) 
         O))))  O))         O))O))         O))))  O))         O))
____________________________________________________________________________
C O I N   A D D R E S S   F E T C H   C O M M A N D   F O R   A R C A D E S
</pre>
____________________________________________
**BACKGROUND**<br>  
During building my 'ARCANGEL' arcade machine, I'd implemented a coin acceptor  
and a counter for displaying the in-game credits for the game.<br>  
Soon it became clear that keeping track of the coins inserted was a simple task  
compared to retrieving the remaining credits as the count decreases with each 'game over'.  
After trying to implement existing "cheat engines" like ugtrain, I ended up writing a  
somewhat simple script for my needs.
_____________________________________________
**OBJECTIVE**<br>  
* Writing a background script for running with retroarch / mame-libretro, which can dump the  
memory region where the credits score is stored in each game.  
* A seperate script, using 'scanmem' for finding the address which holds the credits.
* A method for calculating the address from the offset in memory region.  
* Storing the data for all games in a table.

____________________________________________
**FEATURES**<br>  
* Supports address fetching in randomized static memory (misc regions).
* Auto-scanning feature using scanmem and expect with vkbdd virtual keyboard for keypress.
* Triggerhappy support for running commands on coin insert / start press.


  
<!--pre>
╔═╗╔╗  ╦╔═╗╔═╗╔╦╗╦╦  ╦╔═╗
║ ║╠╩╗ ║║╣ ║   ║ ║╚╗╔╝║╣ 
╚═╝╚═╝╚╝╚═╝╚═╝ ╩ ╩ ╚╝ ╚═╝
</pre-->
<!--pre>
   ___|      \      ____|    ___|      \    
  |         _ \     |       |         _ \   
  |        ___ \    __|     |        ___ \  
 \____|  _/    _\  _|      \____|  _/    _\ 
                                            
   COIN ADDRESS FETCH COMMAND FOR ARCADES</pre-->
