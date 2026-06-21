import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

class ProductData {
  final String name, barcode, specification, category, unit, supplier;
  final double? stock, sellPrice, buyPrice;
  final String? uid, error, extBarcode;
  final List<StoreStock> storeStocks;

  const ProductData({
    this.name = '', this.barcode = '', this.specification = '', this.category = '',
    this.unit = '', this.supplier = '', this.stock, this.sellPrice, this.buyPrice,
    this.uid, this.error, this.extBarcode, this.storeStocks = const [],
  });
}

class StoreStock {
  final String storeName;
  final double? stock;
  const StoreStock({required this.storeName, this.stock});
}

/// A single stock change record from Pospal Inventory/StockChangeHistory
class StockChangeRecord {
  final int index;
  final String time;
  final String operator;
  final String changeType;
  final double? stockChange;
  final double? correctedStock;
  final String remark;

  const StockChangeRecord({
    required this.index,
    required this.time,
    required this.operator,
    required this.changeType,
    this.stockChange,
    this.correctedStock,
    required this.remark,
  });
}

/// Result of a stock history query for one store
class StockHistoryResult {
  final String storeId;
  final String storeName;
  final List<StockChangeRecord> records;
  final String? error;

  const StockHistoryResult({
    required this.storeId,
    required this.storeName,
    this.records = const [],
    this.error,
  });
}

// Unit UIDs differ per store — must use the correct map for each store
const Map<String, Map<String, String>> _unitUidsByStore = {
  '5634817': { // 总部
    'each': '1716997450288771749', 'box': '1716997532868211886', 'pack': '1716997545165229073',
    'bottle': '1716997563016102148', 'meter': '1716997571111667571', 'pair': '1734372628681491096',
  },
  '5634818': { // C1
    'each': '1716997673367646947', 'box': '1716997676993589134', 'pack': '1716997681666731964',
    'bottle': '1716997686438940001', 'meter': '1716997691653854018', 'pair': '1734372618959484861',
  },
  '5634821': { // C2
    'each': '1717079007472223232', 'box': '1717082228970222409', 'pack': '1717082234858430986',
    'bottle': '1717082243564117048', 'meter': '1717082251460897796', 'pair': '1734372630626353130',
  },
  '5968885': { // C3
    'each': '1762156916816635684', 'box': '1762156916816487064', 'pack': '1762156916816279100',
    'bottle': '1762156916816425425', 'meter': '1762156916816162409', 'pair': '1762156916816823726',
  },
};

// Category UIDs — parent categories differ per store, child categories are global
const Map<String, Map<String, String>> _categoryUidsByStore = {
  '5634817': {
    '01---灯具电器': '1716803895953887709', '02---汽车配件': '1716803926617450254', '03---五金工具': '1716803940663180981',
    '04---生活用品': '1716816861453477841', '05---厨房卫浴': '1716816893614306229', '06---派对礼盒': '1716816917024708965',
    '07---化妆饰品': '1716816936915862511', '08---体育用品': '1716816959647511873', '09---宠物用品': '1716816976174938382',
    '10%OFF': '1717580099175353225', '10---塑料制品': '1716816990826222021', '11---手机数码': '1716817616000394037',
    '12---茶食饮料': '1716817639434174204', '13---办公文具': '1716817706440335226', '14---儿童玩具': '1716817723394813531',
    '15%OFF': '1717580126971348460', '15---鞋服被褥': '1716817754269422079', '16---花草渔具': '1716820212100884740',
    '17---家具桌椅': '1716832799252645949', '18---医药类': '1716832897981255606', '19---监控探头': '1716832943623877484',
    '20%OFF': '1717580160687994081', '20---电池电瓶': '1716832965068777272', '21---防身自卫': '1716832985714512595',
    '22---相框镜子': '1716833013818567232', '23---窗帘地毯': '1716833062560152331', '24---钱包箱包': '1716833153851866012',
    '25%OFF': '1717580177266450350', '25---通用条码': '1716996999270396027', '26---未分类': '1716997038070988825',
    '27---活动': '1717580015070237346', '30%OFF': '1717580197173269294', '35%OFF': '1717580214465439410',
    '40%OFF': '1717580233001466391', '45%OFF': '1720864559986717693', '50%OFF': '1720864587103466178',
    '55%OFF': '1720864605181269181', '60%OFF': '1720864630055802750', '65%OFF': '1720864642314740300',
    '70%OFF': '1720864656468503518', 'cosplay': '1748591774140626155', '个人洁护': '1721636448448863868',
    '笔记本电脑配件': '1721714605136868882', '灯具': '1723360035060642328', '地毯毛毯': '1721547655486188646',
    '电热器': '1748589985634159461', '电器': '1723360105387697351', '电子数码': '1721714621729394088',
    '电子数码类': '1737447909501220099', '风扇': '1723360089152807134', '化妆用品': '1723020378791976731',
    '快捷菜单': '1737285654498103988', '礼盒礼袋': '1732907839652816666', '美妆电子': '1723020414092248368',
    '汽车配件': '1748602131183648017', '钱包': '1748602058777717591', '清洁护理': '1721648057345699543',
    '生日派对': '1732907893501698104', '圣诞及礼品礼盒': '1737447929280615025', '圣诞树': '1729237717638390042',
    '生活家电': '1721636489979670821', '生活用品': '1721981653616494994', '生活用品类': '1737447820067319603',
    '书包餐包化妆包': '1748602038072716605', '数码线材': '1748602240166756383', '手机配件': '1721714525522904525',
    '袜子手套帽子围巾': '1748591836804381806', '玩具及学习用品': '1737447555276708181', '卫浴用品': '1721580788028807783',
    '无': '0', '五金灯具开关': '1737447841352420446', '线材开关插座': '1723370633463984675',
    '香薰香精': '1721593246882865390', '项链饰品': '1723020399688858411', '行李箱包': '1748602024852124150',
    '饮料': '1727334948421725430', '音响': '1748592043149962767', '装饰摆件': '1721547732404588329',
    '被子毛毯枕头': '1748591986417156390', '车灯': '1748601936987405653', '厨房厨具': '1721580749317105270',
    '窗帘用品': '1721547515326184087', '儿童自行车摩托车': '1748601959414975298',
    '内衣裤打底裤衣服裤子': '1748591941333517612', '拖鞋棉鞋': '1748591911539816046',
  },
  '5634818': {
    '01---灯具电器': '1716994221539160022', '02---汽车配件': '1716994516205407363', '03---五金工具': '1716994655591842785',
    '04---生活用品': '1716994761833115830', '05---厨房卫浴': '1716994870270210367', '06---派对礼盒': '1716994980462442505',
    '07---化妆饰品': '1716995153960980697', '08---体育用品': '1716995172669216236', '09---宠物用品': '1716995175190185720',
    '10%OFF': '1717580099175353225', '10---塑料制品': '1716995201193146492', '11---手机数码': '1716995212309269697',
    '12---茶食饮料': '1716995224250292025', '13---办公文具': '1716995236853381908', '14---儿童玩具': '1716995256244755841',
    '15%OFF': '1717580126971348460', '15---鞋服被褥': '1716995266201735927', '16---花草渔具': '1716995278253596221',
    '17---家具桌椅': '1716995286433868461', '18---医药类': '1716995296863391212', '19---监控探头': '1716995306182145743',
    '20%OFF': '1717580160687994081', '20---电池电瓶': '1716995458120344170', '21---防身自卫': '1716995467113548658',
    '22---相框镜子': '1716995476185972317', '23---窗帘地毯': '1716995485892178023', '24---钱包箱包': '1716995493912788089',
    '25%OFF': '1717580177266450350', '25---通用条码': '1716996999270396027', '26---未分类': '1716997038070988825',
    '27---活动': '1717580015070237346', '30%OFF': '1717580197173269294', '35%OFF': '1717580214465439410',
    '40%OFF': '1717580233001466391', '45%OFF': '1720864559986717693', '50%OFF': '1720864587103466178',
    '55%OFF': '1720864605181269181', '60%OFF': '1720864630055802750', '65%OFF': '1720864642314740300',
    '70%OFF': '1720864656468503518', 'cosplay': '1748591774140626155', '个人洁护': '1721636448448863868',
    '笔记本电脑配件': '1721714605136868882', '灯具': '1723360035060642328', '地毯毛毯': '1721547655486188646',
    '电热器': '1748589985634159461', '电器': '1723360105387697351', '电子数码': '1721714621729394088',
    '电子数码类': '1737447909501220099', '风扇': '1723360089152807134', '化妆用品': '1723020378791976731',
    '快捷菜单': '1737285654498103988', '礼盒礼袋': '1732907839652816666', '美妆电子': '1723020414092248368',
    '汽车配件': '1748602131183648017', '钱包': '1748602058777717591', '清洁护理': '1721648057345699543',
    '生日派对': '1732907893501698104', '圣诞及礼品礼盒': '1737447929280615025', '圣诞树': '1729237717638390042',
    '生活家电': '1721636489979670821', '生活用品': '1721981653616494994', '生活用品类': '1737447820067319603',
    '书包餐包化妆包': '1748602038072716605', '数码线材': '1748602240166756383', '手机配件': '1721714525522904525',
    '袜子手套帽子围巾': '1748591836804381806', '玩具及学习用品': '1737447555276708181', '卫浴用品': '1721580788028807783',
    '无': '0', '五金灯具开关': '1737447841352420446', '线材开关插座': '1723370633463984675',
    '香薰香精': '1721593246882865390', '项链饰品': '1723020399688858411', '行李箱包': '1748602024852124150',
    '饮料': '1727334948421725430', '音响': '1748592043149962767', '装饰摆件': '1721547732404588329',
    '被子毛毯枕头': '1748591986417156390', '车灯': '1748601936987405653', '厨房厨具': '1721580749317105270',
    '窗帘用品': '1721547515326184087', '儿童自行车摩托车': '1748601959414975298',
    '内衣裤打底裤衣服裤子': '1748591941333517612', '拖鞋棉鞋': '1748591911539816046',
  },
  '5634821': {
    '01---灯具电器': '1717089797822908812', '02---汽车配件': '1717089810879884784', '03---五金工具': '1717089821140554932',
    '04---生活用品': '1717089835068748781', '05---厨房卫浴': '1717089843023684073', '06---派对礼盒': '1717089852316194520',
    '07---化妆饰品': '1717089863556993671', '08---体育用品': '1717089872049739146', '09---宠物用品': '1717089880055748512',
    '10%OFF': '1717580099175353225', '10---塑料制品': '1717089887575445554', '11---手机数码': '1717089894031964893',
    '12---茶食饮料': '1717089901626328153', '13---办公文具': '1717089908790338571', '14---儿童玩具': '1717089915659772669',
    '15%OFF': '1717580126971348460', '15---鞋服被褥': '1717089923697653857', '16---花草渔具': '1717089929752873767',
    '17---家具桌椅': '1717089938888605339', '18---医药类': '1717089945306840638', '19---监控探头': '1717089953535286099',
    '20%OFF': '1717580160687994081', '20---电池电瓶': '1717089960373492712', '21---防身自卫': '1717089965471591247',
    '22---相框镜子': '1717089971973437505', '23---窗帘地毯': '1717089978122177067', '24---钱包箱包': '1717089985279682743',
    '25%OFF': '1717580177266450350', '25---通用条码': '1717089993159420838', '26---未分类': '1717089997777531112',
    '27---活动': '1717580015070237346', '30%OFF': '1717580197173269294', '35%OFF': '1717580214465439410',
    '40%OFF': '1717580233001466391', '45%OFF': '1720864559986717693', '50%OFF': '1720864587103466178',
    '55%OFF': '1720864605181269181', '60%OFF': '1720864630055802750', '65%OFF': '1720864642314740300',
    '70%OFF': '1720864656468503518', 'cosplay': '1748591774140626155', '个人洁护': '1721636448448863868',
    '笔记本电脑配件': '1721714605136868882', '灯具': '1723360035060642328', '地毯毛毯': '1721547655486188646',
    '电热器': '1748589985634159461', '电器': '1723360105387697351', '电子数码': '1721714621729394088',
    '电子数码类': '1737447909501220099', '风扇': '1723360089152807134', '化妆用品': '1723020378791976731',
    '快捷菜单': '1737285654498103988', '礼盒礼袋': '1732907839652816666', '美妆电子': '1723020414092248368',
    '汽车配件': '1748602131183648017', '钱包': '1748602058777717591', '清洁护理': '1721648057345699543',
    '生日派对': '1732907893501698104', '圣诞及礼品礼盒': '1737447929280615025', '圣诞树': '1729237717638390042',
    '生活家电': '1721636489979670821', '生活用品': '1721981653616494994', '生活用品类': '1737447820067319603',
    '书包餐包化妆包': '1748602038072716605', '数码线材': '1748602240166756383', '手机配件': '1721714525522904525',
    '袜子手套帽子围巾': '1748591836804381806', '玩具及学习用品': '1737447555276708181', '卫浴用品': '1721580788028807783',
    '无': '0', '五金灯具开关': '1737447841352420446', '线材开关插座': '1723370633463984675',
    '香薰香精': '1721593246882865390', '项链饰品': '1723020399688858411', '行李箱包': '1748602024852124150',
    '饮料': '1727334948421725430', '音响': '1748592043149962767', '装饰摆件': '1721547732404588329',
    '被子毛毯枕头': '1748591986417156390', '车灯': '1748601936987405653', '厨房厨具': '1721580749317105270',
    '窗帘用品': '1721547515326184087', '儿童自行车摩托车': '1748601959414975298',
    '内衣裤打底裤衣服裤子': '1748591941333517612', '拖鞋棉鞋': '1748591911539816046',
  },
  '5968885': {
    '01---灯具电器': '1716803895953887709', '02---汽车配件': '1716803926617450254', '03---五金工具': '1716803940663180981',
    '04---生活用品': '1716816861453477841', '05---厨房卫浴': '1716816893614306229', '06---派对礼盒': '1716816917024708965',
    '07---化妆饰品': '1716816936915862511', '08---体育用品': '1716816959647511873', '09---宠物用品': '1716816976174938382',
    '10%OFF': '1717580099175353225', '10---塑料制品': '1716816990826222021', '11---手机数码': '1716817616000394037',
    '12---茶食饮料': '1716817639434174204', '13---办公文具': '1716817706440335226', '14---儿童玩具': '1716817723394813531',
    '15%OFF': '1717580126971348460', '15---鞋服被褥': '1716817754269422079', '16---花草渔具': '1716820212100884740',
    '17---家具桌椅': '1716832799252645949', '18---医药类': '1716832897981255606', '19---监控探头': '1716832943623877484',
    '20%OFF': '1717580160687994081', '20---电池电瓶': '1716832965068777272', '21---防身自卫': '1716832985714512595',
    '22---相框镜子': '1716833013818567232', '23---窗帘地毯': '1716833062560152331', '24---钱包箱包': '1716833153851866012',
    '25%OFF': '1717580177266450350', '25---通用条码': '1716996999270396027', '26---未分类': '1716997038070988825',
    '27---活动': '1717580015070237346', '30%OFF': '1717580197173269294', '35%OFF': '1717580214465439410',
    '40%OFF': '1717580233001466391', '45%OFF': '1720864559986717693', '50%OFF': '1720864587103466178',
    '55%OFF': '1720864605181269181', '60%OFF': '1720864630055802750', '65%OFF': '1720864642314740300',
    '70%OFF': '1720864656468503518', 'cosplay': '1748591774140626155', '个人洁护': '1721636448448863868',
    '笔记本电脑配件': '1721714605136868882', '灯具': '1723360035060642328', '地毯毛毯': '1721547655486188646',
    '电热器': '1748589985634159461', '电器': '1723360105387697351', '电子数码': '1721714621729394088',
    '电子数码类': '1737447909501220099', '风扇': '1723360089152807134', '化妆用品': '1723020378791976731',
    '快捷菜单': '1737285654498103988', '礼盒礼袋': '1732907839652816666', '美妆电子': '1723020414092248368',
    '汽车配件': '1748602131183648017', '钱包': '1748602058777717591', '清洁护理': '1721648057345699543',
    '生日派对': '1732907893501698104', '圣诞及礼品礼盒': '1737447929280615025', '圣诞树': '1729237717638390042',
    '生活家电': '1721636489979670821', '生活用品': '1721981653616494994', '生活用品类': '1737447820067319603',
    '书包餐包化妆包': '1748602038072716605', '数码线材': '1748602240166756383', '手机配件': '1721714525522904525',
    '袜子手套帽子围巾': '1748591836804381806', '玩具及学习用品': '1737447555276708181', '卫浴用品': '1721580788028807783',
    '无': '0', '五金灯具开关': '1737447841352420446', '线材开关插座': '1723370633463984675',
    '香薰香精': '1721593246882865390', '项链饰品': '1723020399688858411', '行李箱包': '1748602024852124150',
    '饮料': '1727334948421725430', '音响': '1748592043149962767', '装饰摆件': '1721547732404588329',
    '被子毛毯枕头': '1748591986417156390', '车灯': '1748601936987405653', '厨房厨具': '1721580749317105270',
    '窗帘用品': '1721547515326184087', '儿童自行车摩托车': '1748601959414975298',
    '内衣裤打底裤衣服裤子': '1748591941333517612', '拖鞋棉鞋': '1748591911539816046',
  },
};

const Map<String, String> _supplierUids = {
  'A01': '899009567624761604', 'A02-A04-N9': '416171714438324527', 'A034': '532894013101468345',
  'A10': '316782780092469295', 'A107': '323077353124735781', 'A142': '1139529897406009086',
  'A18': '859508982322869305', 'A292': '756799647701736004', 'A3-A32-A33(行李箱)': '457464435963675020',
  'A407毛线': '479764158468246877', 'A408': '580978347076107144', 'A410(A4-10)': '896329615708985017',
  'A45(A4-5玩具店)': '623564136247158450', 'B01': '160558730743420195', 'B08毛毯城': '771193352851820104',
  'B10': '369943156244707615', 'B11(手机壳)': '866462052574192193', 'B13': '1069903426093151235',
  'B16': '1108017991810224912', 'B19': '490555859439327164', 'B27': '584351367117310704',
  'B33(手机壳、手机膜)': '222343012274327278', 'B34': '294274671935296535', 'B46': '1114001002562214192',
  'B54(anni)': '817027465620791476', 'B58枪店': '574656588088849938', 'B59': '690975872679049059',
  'B62': '908707614140879847', 'B64': '962422360051382623', 'B65': '1062476773534927505',
  'BJH(百佳惠超市)': '405611462215963528', 'C01': '30141739436235299', 'C04': '130039523424885199',
  'C06': '734581930898049856', 'C08': '96870443051591009', 'C104': '1134534508382560915',
  'C108': '114434418807107160', 'C12': '1043381934491318716', 'C17眼镜': '424081473579450568',
  'C21': '407872415107226824', 'C216(印度香)': '7088162153830422', 'C22': '1088917931354707024',
  'C24C25': '194869307536138462', 'C308': '715395956657502870', 'C34': '319688808634506999',
  'C37': '439904318133541889', 'C4': '824508802306313533', 'C43': '955268365567912417',
  'C88': '1109451221901075977', 'CD床垫': '470163177454097039', 'D104(林立)': '725596732127633607',
  'D313': '918907930002908328', 'D317': '72837722001060402', 'D326': '438297540341887002',
  'D327': '158747705334864751', 'DDSJ当地书籍(ddsj)': '248662171244964637',
  'DDYL(当地饮料)': '965210643816063033', 'E115': '311635021076765943', 'E12': '37360021291011631',
  'E18': '960594450461983620', 'F01-F02': '1012042854578281646', 'F05': '133207540280466416',
  'F08': '180164537142144785', 'F09': '1019356821465302993', 'F10A': '227116189604730955',
  'F10B': '770180509253013764', 'F10C(f10c)': '951762051718303722', 'F21': '540043752456560367',
  'F22': '574779508135689405', 'F33': '134998803447876086', 'G1': '865983407295157864',
  'G12': '1066145033007878464', 'G21': '929357406168806605', 'G27': '996074309629022224',
  'G39-G40(监控)': '535511481747168517', 'G42': '802636306788131659', 'G45': '1036557805383219502',
  'G5': '670245849254872463', 'G51': '45832615716413125', 'G52': '248560427057944783',
  'G56-G57': '1080176295703425661', 'H76': '156133032065611603', 'H78': '1134559147868187749',
  'HELLO TODAY': '419982666956583591', 'HILOOK A275': '505463438652242941',
  'JESON监控(D442)': '178385083254216886', 'JIAOHUI教会家具店': '1115655144880209432',
  'JJD(约堡家具店)': '991840144256458067', 'JJL佳佳乐jjl': '886590028779443844',
  'JZ镜子工厂': '328994781447878120', 'KD康德kd': '37790087008251562', 'L02': '812914505630391088',
  'L128': '79959985094536990', 'L144': '549980933191375229', 'L228': '95717256545864694',
  'L5': '170411626420710101', 'LFHJ龙发货架lfhj': '689430122917834778',
  'LSX隆升行': '726125380189773578', 'M101': '640951427701485641', 'M140': '192824238372672354',
  'M213': '792599725118590758', 'M23': '257486029645875290', 'M30': '713583044663653884',
  'MOMO(momo)-N1': '382204939003114541', 'MUCH BETTER': '637537256014696645',
  'N101': '1049139820392449433', 'N113': '300854981938366192', 'N68': '5799336938495667',
  'SASA(sasa)': '870582617434885345', 'T1': '929036604642491617',
  'TESCO-E3-Tina(e3)': '555507049303245579', 'U19': '1146173935741699',
  'V71': '152995126142420615', 'WFL万福来wfl': '413823585007907543',
  'WH208': '766270411930944475', 'WH219': '852354285178523032', 'WH227': '488578707461578462',
  'YDCL印度窗帘配件(ydcl)': '342166130789434678', 'YDDT印度地毯yddt': '310435286145001834',
  'YDSF印度沙发ydsf': '881400571665533946', 'ZGR中国人地毯': '432786241484365156',
  'ZZJ珍珠姐国旗': '638502360212026533', '无': '0',
};

class QueryService {
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final String baseUrl;
  final String cookie;
  final HttpClient _client = HttpClient();

  QueryService({required this.baseUrl, required this.cookie});

  void dispose() => _client.close();

  /// Filter placeholder values that API returns when ext barcode column is empty.
  /// The HTML table may contain "—" (em dash), "无", whitespace, etc.
  static String _cleanExtBarcode(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t == '—' || t == '–' || t == '-' || t == '无' || t == '暂无' || t == '...') return '';
    return t;
  }

  /// Look up unit UID for a specific store (public for use by result_sheet copyStore logic)
  static String? unitUidForStore(String userId, String unitName) {
    return _unitUidsByStore[userId]?[unitName];
  }

  /// Look up category UID for a specific store (public for use by result_sheet copyStore logic)
  static String? categoryUidForStore(String userId, String name) {
    return _categoryUidsByStore[userId]?[name];
  }

  Future<ProductData> searchBarcode(String barcode, {List<Map<String, String>>? subUsers, String? primaryStoreId}) async {
    final url = baseUrl.replaceAll(RegExp(r'/$'), '');
    final code = barcode.trim();
    if (code.isEmpty) return const ProductData(error: '条码为空');

    try {
      final prefs = await SharedPreferences.getInstance();

      // Primary store query
      var queryId = primaryStoreId ?? prefs.getString('user_id_$url');
      if (queryId == null) {
        queryId = await _fetchUserId(url);
        if (queryId != null) await prefs.setString('user_id_$url', queryId);
      }
      if (queryId == null) return const ProductData(error: '无法获取门店信息');

      final primary = await _queryStore(url, queryId, code);
      if (primary.error != null) return primary;

      // Query other stores for stock
      if (subUsers != null && subUsers.isNotEmpty) {
        final stocks = <StoreStock>[];
        for (final su in subUsers) {
          final suId = su['id'] ?? '';
          final suName = su['label'] ?? su['name'] ?? '';
          if (suId.isEmpty) continue;
          if (suId == queryId) {
            stocks.add(StoreStock(storeName: suName, stock: primary.stock));
          } else {
            final r = await _queryStore(url, suId, code);
            stocks.add(StoreStock(storeName: suName, stock: r.stock));
          }
        }
        return ProductData(
          name: primary.name, barcode: primary.barcode,
          specification: primary.specification, category: primary.category,
          unit: primary.unit, supplier: primary.supplier,
          stock: primary.stock, sellPrice: primary.sellPrice, buyPrice: primary.buyPrice,
          uid: primary.uid, extBarcode: primary.extBarcode, storeStocks: stocks,
        );
      }

      return primary;
    } catch (e) {
      return ProductData(error: '查询异常: $e');
    }
  }

  Future<ProductData> _queryStore(String url, String userId, String code) async {
    final formData = _encode({
      'userId': userId, 'enable': '1', 'productTagUidsJson': '[]',
      'keyword': code, 'groupBySpu': 'false', 'categorysJson': '[]',
      'supplierUid': '', 'categoryType': '', 'pageIndex': '1', 'pageSize': '20',
      'orderColumn': '', 'asc': 'true',
    });

    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$url/Product/LoadProductsByPage'));
      _setHeaders(req, url, 'application/x-www-form-urlencoded; charset=UTF-8');
      req.write(formData);
      final resp = await req.close().timeout(const Duration(seconds: 15));

      if (resp.statusCode == 302) {
        final loc = resp.headers.value('location') ?? '';
        if (loc.contains('signin')) return const ProductData(error: '登录已过期');
      }
      if (resp.statusCode != 200) return ProductData(error: 'HTTP ${resp.statusCode}');

      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['successed'] != true) return const ProductData(error: '查询失败');

      final html = data['contentView'] as String? ?? '';
      if (html.isEmpty) return const ProductData(error: '未找到');

      return await _parseProductRow(html, code);
    } finally {
      client.close();
    }
  }

  Future<String?> _fetchUserId(String url) async {
    try {
      final req = await _client.getUrl(Uri.parse('$url/Product/Manage'));
      _setHeaders(req, url, 'text/html,application/xhtml+xml');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final m = RegExp(r'var\s+currentUserId\s*=\s*(\d+)\s*;').firstMatch(body);
      if (m != null) return m.group(1);
      final m2 = RegExp(r'''currentUserId['"]?\s*[:=]\s*['"]?(\d+)['"]?''', caseSensitive: false).firstMatch(body);
      return m2?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<ProductData> _parseProductRow(String html, String code) async {
    // Try dynamic column mapping first, fall back to hardcoded legacy
    final colMap = _parseTableHeader(html);
    if (colMap.isNotEmpty) {
      final result = _parseProductRowDynamic(html, code, colMap);
      if (result != null) return result;
    }
    return _parseProductRowLegacy(html, code);
  }

  /// Known column data-name → canonical field mapping.
  /// Covers both English and Chinese header labels observed in Pospal HTML.
  static const Map<String, String> _colFieldMap = {
    'name': 'name', 'productname': 'name', 'productName': 'name', '商品名称': 'name', '商品名': 'name', '名称': 'name',
    'barcode': 'barcode', 'productBarcode': 'barcode', '条码': 'barcode', '商品条码': 'barcode',
    'extBarcode': 'extBarcode', 'extbarcode': 'extBarcode', 'productExtBarcode': 'extBarcode',
    '多码': 'extBarcode', '扩展码': 'extBarcode', '商品多码': 'extBarcode',
    'specification': 'spec', 'spec': 'spec', 'attribute6': 'spec', '规格': 'spec', '商品规格': 'spec',
    'category': 'category', 'categoryName': 'category', '分类': 'category', '商品分类': 'category',
    'unit': 'unit', 'baseUnit': 'unit', 'baseUnitName': 'unit', '单位': 'unit', '商品单位': 'unit',
    'supplier': 'supplier', 'supplierName': 'supplier', '供货商': 'supplier', '供应商': 'supplier',
    'stock': 'stock', 'stockQuantity': 'stock', '库存': 'stock', '商品库存': 'stock',
    'sellPrice': 'sellPrice', 'sellprice': 'sellPrice', '售价': 'sellPrice', '销售价': 'sellPrice',
    'buyPrice': 'buyPrice', 'buyprice': 'buyPrice', '进价': 'buyPrice', '进货价': 'buyPrice',
  };

  /// Parse a single product row using dynamic column indices from `_parseTableHeader`.
  /// Returns null when the row doesn't match the searched barcode.
  ProductData? _parseProductRowDynamic(String html, String code, Map<String, int> colMap) {
    // Build index lookups from the parsed header
    final idx = <String, int>{};
    for (final e in colMap.entries) {
      final canonical = _colFieldMap[e.key];
      if (canonical != null && !idx.containsKey(canonical)) {
        idx[canonical] = e.value;
      }
    }
    // Must have at least barcode column to match
    if (!idx.containsKey('barcode')) return null;

    final rowRegex = RegExp(r'<tr\s+data="\d+"\s+data-uid="(\d+)"[^>]*>([\s\S]*?)</tr>', caseSensitive: false);
    for (final m in rowRegex.allMatches(html)) {
      final uid = m.group(1)!;
      final tds = RegExp(r'<td[^>]*>([\s\S]*?)</td>', caseSensitive: false)
          .allMatches(m.group(2)!).map((td) => td.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim()).toList();
      String g(int i) => i < tds.length ? tds[i] : '';
      double? n(String s) { final v = double.tryParse(s); return v ?? 0; }

      final bc = g(idx['barcode']!);
      if (bc == code || tds.any((t) => t == code)) {
        return ProductData(
          uid: uid,
          name: g(idx['name'] ?? 3),
          barcode: bc,
          specification: g(idx['spec'] ?? 8),
          category: g(idx['category'] ?? 10),
          unit: g(idx['unit'] ?? 12),
          supplier: g(idx['supplier'] ?? 19),
          stock: n(g(idx['stock'] ?? 11)),
          sellPrice: n(g(idx['sellPrice'] ?? 14)),
          buyPrice: n(g(idx['buyPrice'] ?? 13)),
          extBarcode: _cleanExtBarcode(g(idx['extBarcode'] ?? 6)),
        );
      }
    }
    return null;
  }

  Map<String, int> _parseTableHeader(String html) {
    final colMap = <String, int>{};
    final theadMatch = RegExp(r'<thead[^>]*>([\s\S]*?)</thead>', caseSensitive: false).firstMatch(html);
    if (theadMatch == null) return colMap;
    final theadHtml = theadMatch.group(1)!;

    final dataRegex = RegExp(r'data="([^"]*)"', caseSensitive: false);
    var idx = 0;
    var searchStart = 0;
    while (true) {
      final thMatch = RegExp(r'<th\b', caseSensitive: false).firstMatch(theadHtml.substring(searchStart));
      if (thMatch == null) break;
      final thTagStart = searchStart + thMatch.start;
      final thTagEnd = theadHtml.indexOf('>', thTagStart);
      if (thTagEnd == -1) break;
      final thTag = theadHtml.substring(thTagStart, thTagEnd + 1);
      final dm = dataRegex.firstMatch(thTag);
      if (dm != null) {
        final colName = dm.group(1)?.trim();
        if (colName != null && colName.isNotEmpty) colMap[colName] = idx;
      }
      idx++;
      searchStart = thTagEnd + 1;
    }
    return colMap;
  }

  ProductData _parseProductRowLegacy(String html, String code) {
    const cn = 3, cb = 4, cs = 8, cc = 10, cu = 12, csu = 19, cst = 11, cse = 14, cby = 13;

    final rowRegex = RegExp(r'<tr\s+data="\d+"\s+data-uid="(\d+)"[^>]*>([\s\S]*?)</tr>', caseSensitive: false);
    for (final m in rowRegex.allMatches(html)) {
      final uid = m.group(1)!;
      final tds = RegExp(r'<td[^>]*>([\s\S]*?)</td>', caseSensitive: false)
          .allMatches(m.group(2)!).map((td) => td.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim()).toList();
      String g(int i) => i < tds.length ? tds[i] : '';
      double? n(String s) { final v = double.tryParse(s); return v ?? 0; }

      if (g(cb) == code || tds.any((t) => t == code)) {
        return ProductData(
          uid: uid, name: g(cn), barcode: g(cb),
          specification: g(cs), category: g(cc),
          unit: g(cu).isEmpty ? '—' : g(cu), supplier: g(csu),
          stock: n(g(cst)), sellPrice: n(g(cse)), buyPrice: n(g(cby)),
          extBarcode: _cleanExtBarcode(g(6)),
        );
      }
    }
    return const ProductData(error: '未找到该条码商品');
  }

  /// Save/update product in a specific store (ported from pospal_stock_app)
  ///
  /// Uses a fresh HttpClient for each call to avoid connection reuse issues.
  Future<String?> saveProduct({
    required String userId,
    required String barcode,
    String? name, String? specification, String? category,
    String? unit, String? supplier,
    double? buyPrice, double? sellPrice, double? stock,
    String? extBarcodes,
  }) async {
    final url = baseUrl.replaceAll(RegExp(r'/$'), '');
    final code = barcode.trim();
    if (code.isEmpty) return '条码为空';

    final client = HttpClient();
    try {
      // 1. Search to get productId
      final formData = _encode({
        'userId': userId, 'enable': '1', 'productTagUidsJson': '[]',
        'keyword': code, 'groupBySpu': 'false', 'categorysJson': '[]',
        'supplierUid': '', 'categoryType': '', 'pageIndex': '1', 'pageSize': '20',
        'orderColumn': '', 'asc': 'true',
      });

      final searchReq = await client.postUrl(Uri.parse('$url/Product/LoadProductsByPage'));
      _setHeaders(searchReq, url, 'application/x-www-form-urlencoded; charset=UTF-8');
      searchReq.write(formData);
      final searchResp = await searchReq.close().timeout(const Duration(seconds: 15));
      final searchBody = await searchResp.transform(utf8.decoder).join();

      // Check for redirect (login expired)
      if (searchResp.statusCode == 302) {
        final loc = searchResp.headers.value('location') ?? '';
        if (loc.contains('signin')) return '登录已过期，请重新登录';
      }
      if (searchResp.statusCode != 200) return '搜索失败 HTTP ${searchResp.statusCode}';

      final searchData = jsonDecode(searchBody) as Map<String, dynamic>;
      if (searchData['successed'] != true) return '搜索失败: ${searchData['msg'] ?? '未知错误'}';

      final html = searchData['contentView'] as String? ?? '';
      if (html.isEmpty || !html.contains('<tr')) return '未找到商品（条码=$code 门店=$userId）';

      final productIdMatch = RegExp(r'<tr\s+data="(\d+)"').firstMatch(html);
      if (productIdMatch == null) return '未找到商品ID（条码=$code 门店=$userId）';

      final productId = productIdMatch.group(1)!;

      // 2. FindProduct
      final findReq = await client.postUrl(Uri.parse('$url/Product/FindProduct'));
      _setHeaders(findReq, url, 'application/json, text/javascript, */*');
      findReq.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      findReq.write('productId=$productId');
      final findResp = await findReq.close().timeout(const Duration(seconds: 15));
      final findBody = await findResp.transform(utf8.decoder).join();

      if (findResp.statusCode == 302) {
        final loc = findResp.headers.value('location') ?? '';
        if (loc.contains('signin')) return '登录已过期，请重新登录';
      }
      if (findResp.statusCode != 200) return '获取商品数据失败 HTTP ${findResp.statusCode}';

      final findData = jsonDecode(findBody) as Map<String, dynamic>;
      final product = findData['product'] as Map<String, dynamic>?;
      if (product == null) return '商品数据为空';

      // 3. Modify (including UIDs)
      if (name != null) product['name'] = name;
      if (specification != null) product['attribute6'] = specification;
      if (category != null && category.isNotEmpty) {
        product['categoryName'] = category;
        product['categoryUid'] = categoryUidForStore(userId, category) ?? product['categoryUid'];
      }
      if (unit != null && unit.isNotEmpty) {
        product['baseUnitName'] = unit;
        final uid = unitUidForStore(userId, unit);
        if (uid != null) {
          product['productUnitExchangeList'] = [
            {'productUnitUid': uid, 'unitQuantity': 1, 'baseUnitQuantity': 1, 'isBase': 1, 'isRequest': 0, 'isTicket': -1, 'isDiscard': -1, 'productUnitName': unit}
          ];
        }
      }
      if (supplier != null && supplier.isNotEmpty) {
        product['supplierName'] = supplier;
        final suid = _supplierUids[supplier];
        if (suid != null && suid.isNotEmpty) {
          product['supplierUid'] = suid;
          product['supplierRangeList'] = [{'supplierUid': suid, 'supplierName': supplier, 'isDefault': '1'}];
        }
      }
      if (buyPrice != null) product['buyPrice'] = buyPrice;
      if (sellPrice != null) product['sellPrice'] = sellPrice;
      if (stock != null) {
        product['stock'] = stock;
        product['stockQuantity'] = stock;
      }
      if (extBarcodes != null) {
        // Merge with existing entries to preserve uid/id fields from FindProduct
        final newCodes = extBarcodes.split(',').map((b) => b.trim()).where((b) => b.isNotEmpty).toSet();
        final existing = (product['productExtBarcodes'] as List?)?.cast<Map<String, dynamic>>() ?? [];

        // Index existing entries by their extBarcode value
        final existingByCode = <String, Map<String, dynamic>>{};
        for (final entry in existing) {
          final code = entry['extBarcode']?.toString() ?? '';
          if (code.isNotEmpty) existingByCode[code] = entry;
        }

        final result = <Map<String, dynamic>>[];
        for (final code in newCodes) {
          if (existingByCode.containsKey(code)) {
            // Preserve uid, id and all other fields from FindProduct
            result.add(existingByCode[code]!);
          } else {
            // New entry — server will assign uid on save
            result.add({'extBarcode': code});
          }
        }

        product['productExtBarcodes'] = result;
      }

      // 4. Save
      final productJson = jsonEncode(product);
      final saveData = 'productJson=${Uri.encodeComponent(productJson)}';
      final saveReq = await client.postUrl(Uri.parse('$url/Product/SaveProduct'));
      _setHeaders(saveReq, url, 'application/json, text/javascript, */*');
      saveReq.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      saveReq.write(saveData);
      final saveResp = await saveReq.close().timeout(const Duration(seconds: 15));
      final saveBody = await saveResp.transform(utf8.decoder).join();

      if (saveResp.statusCode == 302) {
        final loc = saveResp.headers.value('location') ?? '';
        if (loc.contains('signin')) return '登录已过期，请重新登录';
      }
      if (saveResp.statusCode != 200) return '保存失败 HTTP ${saveResp.statusCode}';

      final saveResult = jsonDecode(saveBody) as Map<String, dynamic>;
      if (saveResult['successed'] != true) return saveResult['msg'] as String? ?? '保存失败';
      return null;
    } catch (e) {
      return '保存异常: $e';
    } finally {
      client.close();
    }
  }

  /// 新建商品
  ///
  /// 银豹路径: POST /Product/SaveProduct（与修改商品共用同一个端点）
  /// 请求格式: form-encoded，参数 productJson=<完整JSON>
  /// JSON 内 id=0 表示新建，id>0 表示修改已有商品
  ///
  /// 新建流程: ① SaveProduct 建到总部(5634817) → ② CopyNewProductToStores 逐个复制到子门店
  /// 浏览器对应: 新建 → 填写 → 勾选同步 → 保存（自动触发 SaveProduct + 3次 CopyNewProductToStores）
  Future<String?> createProduct({
    required String userId,
    required String barcode,
    required String name,
    String specification = '',
    String category = '',
    String? categoryUid,
    String unit = '—',
    String supplier = '',
    double buyPrice = 0,
    double sellPrice = 0,
    double stock = 0,
    String? extBarcodes,
  }) async {
    final url = baseUrl.replaceAll(RegExp(r'/$'), '');
    final client = HttpClient();
    try {
      // Build new product JSON (matching Pospal native format)
      final product = <String, dynamic>{
        'id': 0,
        'enable': '1',
        'userId': userId,
        'barcode': barcode,
        'name': name,
        'categoryUid': categoryUid ?? '',
        'categoryName': category,
        'sellPrice': sellPrice,
        'buyPrice': buyPrice,
        'isCustomerDiscount': '1',
        'customerPrice': '',
        'sellPrice2': '',
        'pinyin': '',
        'supplierUid': supplier.isNotEmpty ? _supplierUids[supplier] : null,
        'supplierName': supplier.isNotEmpty ? supplier : '无',
        'supplierRangeList': supplier.isNotEmpty ? [
          {'supplierUid': _supplierUids[supplier] ?? '', 'supplierName': supplier, 'isDefault': '1'}
        ] : [],
        'productionDate': '',
        'shelfLife': '',
        'maxStock': '',
        'minStock': '',
        'description': '',
        'noStock': 0,
        'stock': '$stock',
        'attribute6': specification,
        'attribute9': null,
        'productCommonAttribute': {'canAppointed': 0},
        'baseUnitName': unit,
        'customerPrices': [],
        'productUnitExchangeList': (() { final uid = unitUidForStore(userId, unit); return uid != null ? [
          {'productUnitUid': uid, 'unitQuantity': 1, 'baseUnitQuantity': 1, 'isBase': 1, 'isRequest': 0, 'isTicket': -1, 'isDiscard': -1, 'productUnitName': unit}
        ] : []; })(),
        'attribute1': '',
        'attribute2': '',
        'attribute3': '',
        'attribute4': '',
        'productimages': [],
        'productTags': [
          {'uid': '1717232007906861613', 'name': '税率'},
        ],
        'productExtBarcodes': extBarcodes?.isNotEmpty == true
            ? extBarcodes!.split(',').map((b) => {'extBarcode': b.trim()}).toList()
            : [],
      };

      final productJson = jsonEncode(product);
      final saveData = 'productJson=${Uri.encodeComponent(productJson)}';
      final req = await client.postUrl(Uri.parse('$url/Product/SaveProduct'));
      _setHeaders(req, url, 'application/json, text/javascript, */*');
      req.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      req.write(saveData);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return '保存失败 HTTP ${resp.statusCode}';
      final result = jsonDecode(body) as Map<String, dynamic>;
      if (result['successed'] != true) return result['msg'] as String? ?? '保存失败';
      return null;
    } catch (e) {
      return '新建异常: $e';
    } finally {
      client.close();
    }
  }

  /// 原生同步 API — 将商品从一家门店复制到另一家门店
  ///
  /// 银豹路径: POST /Product/CopyNewProductToStores
  /// 浏览器操作: 新建商品 → 勾选「同步到子门店」→ 保存 → 自动触发此 API
  ///
  /// 参数说明（均从 F12 Network Payload 抓取，2026-06）:
  ///   fromUserId  来源门店的用户ID（总部: 5634817）
  ///   toUserId    目标门店的用户ID（C1: 5634818, C2: 5634821, C3: 5968885）
  ///   productJson 完整商品 JSON（与 SaveProduct 相同的结构，userId 字段为来源门店的 ID）
  ///
  /// 调用时机: SaveProduct 成功后，对每个子门店分别调用一次
  /// 返回 null 表示同步成功，否则返回错误信息
  ///
  /// 门店 ID 对照表:
  ///   总部 = 5634817
  ///   C1   = 5634818
  ///   C2   = 5634821
  ///   C3   = 5968885
  Future<String?> copyToStore({
    required String fromUserId,
    required String toUserId,
    required Map<String, dynamic> productJson,
  }) async {
    final url = baseUrl.replaceAll(RegExp(r'/$'), '');
    try {
      final productJsonStr = jsonEncode(productJson);
      final data = 'fromUserId=${Uri.encodeComponent(fromUserId)}&userId=${Uri.encodeComponent(toUserId)}&productJson=${Uri.encodeComponent(productJsonStr)}';

      // Use fresh client each time to avoid connection reuse issues
      final copyClient = HttpClient();
      try {
        final req = await copyClient.postUrl(Uri.parse('$url/Product/CopyNewProductToStores'));
      _setHeaders(req, url, 'application/json, text/javascript, */*');
      req.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      req.write(data);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return '同步失败 HTTP ${resp.statusCode}';
      final result = jsonDecode(body) as Map<String, dynamic>;
        if (result['successed'] != true) return result['msg'] as String? ?? '同步失败';
        return null;
      } finally {
        copyClient.close();
      }
    } catch (e) {
      return '同步异常: $e';
    }
  }

  /// Save product directly from a pre-built JSON (for new products)
  ///
  /// Sends the JSON as-is to POST /Product/SaveProduct with form-encoded body.
  /// Returns null on success, error message string on failure.
  Future<String?> saveProductFromJson({
    required String userId,
    required Map<String, dynamic> productJson,
  }) async {
    final url = baseUrl.replaceAll(RegExp(r'/$'), '');
    final client = HttpClient();
    try {
      final jsonStr = jsonEncode(productJson);
      final data = 'productJson=${Uri.encodeComponent(jsonStr)}';
      final req = await client.postUrl(Uri.parse('$url/Product/SaveProduct'));
      _setHeaders(req, url, 'application/json, text/javascript, */*');
      req.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      req.write(data);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();

      // Check for redirect (login expired)
      if (resp.statusCode == 302) {
        final loc = resp.headers.value('location') ?? '';
        if (loc.contains('signin')) return '登录已过期，请重新登录';
      }
      if (resp.statusCode != 200) {
        // Try to extract error detail from response body
        String detail = 'HTTP ${resp.statusCode}';
        try {
          final errJson = jsonDecode(body) as Map<String, dynamic>;
          if (errJson['msg'] != null) detail = errJson['msg'].toString();
        } catch (_) {
          if (body.length < 200) detail = body;
        }
        return '保存失败: $detail';
      }
      final result = jsonDecode(body) as Map<String, dynamic>;
      if (result['successed'] != true) {
        final msg = result['msg'] as String?;
        if (msg != null && msg.isNotEmpty) return msg;
        // Fallback: return the raw response for debugging
        return '保存失败，服务器返回: ${body.length > 300 ? body.substring(0, 300) : body}';
      }
      return null;
    } catch (e) {
      return '保存异常: $e';
    } finally {
      client.close();
    }
  }

  /// Fetch stock change history for a barcode in a given store.
  ///
  /// POSTs to /Inventory/StockChangeHistory, parses the result table.
  /// [startTime] / [endTime] in yyyy.MM.dd HH:mm format (matching the page's datetime picker).
  Future<StockHistoryResult> fetchStockHistory({
    required String userId,
    required String storeName,
    required String barcode,
    String? startTime,
    String? endTime,
  }) async {
    final url = baseUrl.replaceAll(RegExp(r'/$'), '');
    final client = HttpClient();

    try {
      final params = <String, String>{
        'userId': userId,
        'barcode': barcode,
        'changeType': 'allStockChange',
      };
      if (startTime != null) params['beginDateTime'] = startTime;
      if (endTime != null) params['endDateTime'] = endTime;
      final formData = _encode(params);

      final req = await client.postUrl(Uri.parse('$url/Inventory/LoadStockChangeHistory'));
      _setHeaders(req, url, 'text/html, */*');
      req.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      req.write(formData);
      final resp = await req.close().timeout(const Duration(seconds: 15));

      if (resp.statusCode == 302) {
        final loc = resp.headers.value('location') ?? '';
        if (loc.contains('signin')) {
          return StockHistoryResult(storeId: userId, storeName: storeName, error: '登录已过期');
        }
      }
      if (resp.statusCode != 200) {
        return StockHistoryResult(storeId: userId, storeName: storeName, error: 'HTTP ${resp.statusCode}');
      }

      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (data['successed'] != true) {
        final msg = data['msg'] as String? ?? '查询失败';
        return StockHistoryResult(storeId: userId, storeName: storeName, error: msg);
      }

      final logs = data['stockChangeLogs'] as List? ?? [];
      final records = <StockChangeRecord>[];
      double? prevStock;
      for (var i = 0; i < logs.length; i++) {
        final log = logs[i] as Map<String, dynamic>;
        final exactStock = (log['exactStock'] as num?)?.toDouble();
        final reduce = (log['reduceQuantity'] as num?)?.toDouble() ?? 0;
        final increment = (log['incrementQuantity'] as num?)?.toDouble() ?? 0;
        final update = (log['updateQuantity'] as num?)?.toDouble() ?? 0;
        final remark = log['remark'] as String? ?? '';

        // Operator: CashierNameNumber for sales, fallback to operator fields
        final operator = (log['CashierNameNumber'] ?? log['operatorName'] ?? log['operator'] ?? '-') as String;

        // Calculate stock change
        double? stockChange;
        if (reduce != 0) {
          stockChange = -reduce;
        } else if (increment != 0) {
          stockChange = increment;
        } else if (update != 0) {
          // For sales: updateQuantity is positive, stock goes down → negative
          final ct = (log['changeType'] as String? ?? '').toLowerCase();
          if (ct.contains('sell') || ct.contains('sale')) {
            stockChange = -update;
          } else {
            stockChange = update;
          }
        } else if (exactStock != null && prevStock != null) {
          stockChange = exactStock - prevStock;
        } else if (exactStock != null) {
          final prevMatch = RegExp(r'修改前库存[：:]?\s*([\d.]+)').firstMatch(remark);
          if (prevMatch != null) {
            final prev = double.tryParse(prevMatch.group(1)!);
            if (prev != null) stockChange = exactStock - prev;
          }
        }

        records.add(StockChangeRecord(
          index: i + 1,
          time: log['dateTime'] as String? ?? '',
          operator: operator,
          changeType: _mapChangeType(log['changeType'] as String? ?? ''),
          stockChange: stockChange,
          correctedStock: exactStock,
          remark: remark,
        ));

        if (exactStock != null) prevStock = exactStock;
      }

      return StockHistoryResult(
        storeId: userId,
        storeName: storeName,
        records: records,
      );
    } catch (e) {
      return StockHistoryResult(storeId: userId, storeName: storeName, error: '查询异常: $e');
    } finally {
      client.close();
    }
  }

  /// Map Pospal changeType codes to Chinese display text
  String _mapChangeType(String code) {
    switch (code.toLowerCase()) {
      case 'editstock': return '编辑库存';
      case 'sale': case 'stocksell': return '商品销售';
      case 'return': case 'stockreturn': return '客户退货';
      case 'stockin': return '货流进货';
      case 'stockout': return '货流调出';
      case 'loss': return '商品报损';
      case 'unpack': return '组装拆分';
      case 'anticheckout': return '反结账';
      default: return code;
    }
  }

  void _setHeaders(HttpClientRequest req, String url, String accept) {
    req.headers.set('User-Agent', _ua);
    req.headers.set('Accept', accept);
    req.headers.set('Referer', '$url/Product/Manage');
    req.headers.set('Origin', url);
    req.headers.set('X-Requested-With', 'XMLHttpRequest');
    req.headers.set('Cookie', cookie);
    req.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
    req.followRedirects = false;
  }

  String _encode(Map<String, String> data) {
    return data.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&');
  }
}
