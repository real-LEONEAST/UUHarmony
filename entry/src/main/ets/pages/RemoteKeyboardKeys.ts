export class ComputerKey {
  label:string;
  code:number;
  weight:number;
  modifier:string;
  constructor(label:string,code:number,weight:number=1,modifier:string=''){
    this.label=label;this.code=code;this.weight=weight;this.modifier=modifier;
  }
}
export const COMPUTER_ROWS:ComputerKey[][]=[
  [new ComputerKey('`',192),new ComputerKey('1',49),new ComputerKey('2',50),new ComputerKey('3',51),new ComputerKey('4',52),new ComputerKey('5',53),new ComputerKey('6',54),new ComputerKey('7',55),new ComputerKey('8',56),new ComputerKey('9',57),new ComputerKey('0',48),new ComputerKey('−',189),new ComputerKey('=',187),new ComputerKey('⌫',8,1.6)],
  [new ComputerKey('Tab',9,1.4),new ComputerKey('Q',81),new ComputerKey('W',87),new ComputerKey('E',69),new ComputerKey('R',82),new ComputerKey('T',84),new ComputerKey('Y',89),new ComputerKey('U',85),new ComputerKey('I',73),new ComputerKey('O',79),new ComputerKey('P',80),new ComputerKey('[',219),new ComputerKey(']',221),new ComputerKey('\\',220)],
  [new ComputerKey('Caps',20,1.7),new ComputerKey('A',65),new ComputerKey('S',83),new ComputerKey('D',68),new ComputerKey('F',70),new ComputerKey('G',71),new ComputerKey('H',72),new ComputerKey('J',74),new ComputerKey('K',75),new ComputerKey('L',76),new ComputerKey(';',186),new ComputerKey("'",222),new ComputerKey('Enter',13,2)],
  [new ComputerKey('Shift',160,2,'Shift'),new ComputerKey('Z',90),new ComputerKey('X',88),new ComputerKey('C',67),new ComputerKey('V',86),new ComputerKey('B',66),new ComputerKey('N',78),new ComputerKey('M',77),new ComputerKey(',',188),new ComputerKey('.',190),new ComputerKey('/',191),new ComputerKey('Shift',161,2,'Shift')],
  [new ComputerKey('Ctrl',162,1.4,'Ctrl'),new ComputerKey('Win',91,1.2,'Win'),new ComputerKey('Alt',164,1.2,'Alt'),new ComputerKey('Space',32,6),new ComputerKey('Alt',165,1.2,'Alt'),new ComputerKey('Menu',93,1.2),new ComputerKey('Ctrl',163,1.4,'Ctrl')]
];
export const FUNCTION_KEYS:ComputerKey[]=[new ComputerKey('Esc',27),...Array.from({length:12},(_v,index)=>new ComputerKey('F'+(index+1),112+index))];
export const NAVIGATION_KEYS:ComputerKey[]=[new ComputerKey('Ins',45),new ComputerKey('Home',36),new ComputerKey('PgUp',33),new ComputerKey('Del',46),new ComputerKey('End',35),new ComputerKey('PgDn',34),new ComputerKey('←',37),new ComputerKey('↑',38),new ComputerKey('↓',40),new ComputerKey('→',39),new ComputerKey('PrtSc',44),new ComputerKey('Scroll',145),new ComputerKey('Pause',19)];
export const NUMBER_ROWS:ComputerKey[][]=[
  [new ComputerKey('Num',144),new ComputerKey('/',111),new ComputerKey('×',106),new ComputerKey('−',109)],
  [new ComputerKey('7',103),new ComputerKey('8',104),new ComputerKey('9',105),new ComputerKey('+',107)],
  [new ComputerKey('4',100),new ComputerKey('5',101),new ComputerKey('6',102),new ComputerKey('⌫',8)],
  [new ComputerKey('1',97),new ComputerKey('2',98),new ComputerKey('3',99),new ComputerKey('Enter',13)],
  [new ComputerKey('0',96,2),new ComputerKey('.',110),new ComputerKey('Del',46)]
];
