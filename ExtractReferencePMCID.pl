#!/usr/bin/perl 

# 
# Devin Scannell, 2013 
# 
# GNU GPL v3
# 

unless ( @ARGV ) {
    print <<USAGE;

    Use PLoS ALM API to collect all PMCIDs for all papers publichsed 
    in PLoS or specify a specific PMCID as the commandline argument. 
    Query PMCIDs against Pubmed Central OAI API to obtain reference PMIDs.
    Query PMIDs against either efetch or pmid2doi API to obtain DOIs for 
    references.
    
    $0 pmcid|plos [--no_pmc] [--no_doi] [--start=i] [--stop=i]
    
    --no_pmc : disables querying of PMC and -by extension- DOI look ups. 
    --no_doi : disables  DOI look ups only. 
    --start=i: PLoS API page to start on 
    --stop=i : PLoS API page to end on

    Use case example: 

    Use 3 AWS instances to run on PLoS corpus in 24 hours. 
    
    'nohup ./pmc2doi.pl plos --start=1 --stop=900 > errors &' 

    1-900
    901-1800
    1801-2700

    Contact Devin Scannell.

USAGE
    exit;
}

########################################
# load module and define API URLs
########################################

use Getopt::Long;
use LWP::Simple;
#use XML::Parser;
#use Spreadsheet::WriteExcel;

GetOptions(
    'no_pmc' => \$no_pmc,
    'no_doi' => \$no_doi,
    'start=i' => \$first_page,
    'stop=i' => \$last_page,
    'debug' => \$debug
    );

$, = "\t";
$\ = "\n";

# api urls 

my $pmcoai = "http://www.pubmedcentral.nih.gov/oai/oai.cgi?verb=GetRecord&metadataPrefix=pmc&identifier=oai:pubmedcentral.nih.gov:";
my $pmid2doi_api="http://www.pmid2doi.org/rest/json/doi/";
my $efetch_api="http://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&retmode=xml&id=";
my $plos_api = "http://alm.plos.org/articles.json?order=doi&api_key=ZyWayd2DQs12Q3g&page=";

# output headers 

my $stage = (`whoami` =~ /ec2/ ? 'aws' : 'local');
open( $FHout, ">".join("_", $ARGV[0], ($first_page || 0), ($last_page || 0).".tab" ) );

my @header=qw(
#Query_PMCID
Query_PMID
Query_DOI
Ref_Count
Ref_PMID
Ref_DOI
Ref_Title
);

# plos article stats

my $plos_articles = 78e3;
my $articles_per_page=30;
my $max_pages = int( $plos_articles / $articles_per_page )+1;

$last_page=$max_pages unless $last_page;
$first_page=1 unless $first_page;

########################################
# Choose between single file run mode and 
# iterative calls to plos API 
########################################

my $ask = shift @ARGV;

if ( $ask =~ /^plos$/i ) {
    mkdir('data') unless -e 'data';

    for my $page ( $first_page .. $last_page) {
	my $file = "data/plos.json.".$page;

	# Either use pre-saved files or query PLoS API 

	my $json;
	if ( -e $file ) {
	    open(my $fh, $file);
	    $json .= $_ while <$fh>;
	    close($fh);
	} else {
	    $json = get( $plos_api.$page );
	    open(my $fh, ">$file");
	    print {$fh} $json;
	    close($fh);
	}
	$json =~ s/\"//g;

	# Capture all the PMCIDs on the page 

	my ($art_count,$pmc_count)=(0,0);
	foreach my $pmcid ( $json =~ /pub_med_central:(\w+)/g ) {
	    if ( $pmcid =~ /^(PMC)?\d+$/ ) {
		$pmc_count++;
		&referenceDOI( $pmcid ) unless $no_pmc;
	    } elsif ( $pmcid ne 'null' ) {
		print STDERR " >>>>> $page / $pmcid <<<<< ";
	    }
	    $art_count++;
	}
	$pmc_total += $pmc_count;

	print STDERR $max_pages, $page, $file, $art_count, $pmc_count, $pmc_total;
    }
} else {
    $ask =~ s/^[a-zA-Z]+//;
die($ask) unless $ask =~ /^\d{5,10}$/;
    &referenceDOI( $ask );
}

exit;

########################################
# Subroutines 
########################################

sub referenceDOI {
    my $pmcid = $_[0];
    my $xml = get( $pmcoai.$pmcid );

    print $xml if $debug;
    #my $p1 = new XML::Parser(Style => 'Debug');
    #$p1->parse($xml);
    
    my ($top,$reflist) = split/\<ref\-list\>/, $xml;
    
    ########################################
    # process XML header to get article DOI and PMID 
    ########################################

    my @ids = grep {/article\-id\spub\-id\-type/} split/\n/, $top;
    my ($doi) =map {s/\<[^\>]+\>//g;$_} grep {/doi/} @ids;
    my ($pmid) =map {s/\<[^\>]+\>//g;$_} grep {/pmid/} @ids;
    
    ########################################
    # process XML to get PMID for each reference. 
    # look up reference DOIs using pmid2doi API service.  
    # write table that maps query article DOI to reference DOI.
    ########################################

    my $rec=0;
    print {$FHout} @header;
    foreach my $ref ( split/ref\sid/, $reflist ) {
	next unless ++$rec >1;
	my (@articles, @pub);
	
	# Not all PMC records are \n separated 
	#my @articles = map {s/\<[^\>]+\>//g;$_} grep {/article\-title/} split/\n/, $ref;
	#my @pub = map {s/\<[^\>]+\>//g;$_} grep {/pub\-id/} split/\n/, $ref;
	
	foreach my $title ($ref =~ /\<article\-title\>(.+)\<\/article\-title>/g) {
	    push @articles,($title);
	}
	foreach my $pmidx ($ref =~ /\<pub\-id\spub\-id\-type="pmid"\>(\d+)\<\/(pub\-id)\>/g) {
	    push @pub,$pmidx;
	}
	#die($#articles,$#pub) unless $#articles == $#pub;
	
	my $refdoi;
	unless ( $no_doi || ! @pub ) {
	    $refdoi = &pmid2doi( $pub[0] );	
	    $refdoi = &pmid2doi_entrez( $pub[0] ) unless $refdoi;
	}
	
	print {$FHout} $pmcid, $pmid, $doi, ++$c, ($pub[0] || "NA"), ($refdoi || "NA"), substr(($articles[0] || "NA"), 0, 1000);
    }
}

########################################
# query pmid 2 doi API and parse. 
# need to add some error checking and QC ... 
########################################

sub pmid2doi {
    my $json = get( $pmid2doi_api.$_[0] );
    return ( $json =~ /\"doi\"\:\"([^\"]+)\"/ ? $1 : undef );
}

sub pmid2doi_entrez {
    my $xml =  get( $efetch_api.$_[0] );
    return ( $xml =~ /IdType="doi"\>([^<]+)\<\/ArticleId\>/ ? $1 : undef);   
}
